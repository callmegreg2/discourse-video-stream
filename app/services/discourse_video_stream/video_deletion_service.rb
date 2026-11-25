# frozen_string_literal: true

require "erb"

module DiscourseVideoStream
  class VideoDeletionService
    include ::Service::Base

    CF_VIDEO_DELETE_PATH =
      "https://api.cloudflare.com/client/v4/accounts/%{account_id}/stream/%{video_id}"
    BUNNY_VIDEO_DELETE_PATH =
      "https://video.bunnycdn.com/library/%{library_id}/videos/%{video_id}"

    VALID_VIDEO_ID = /\A[a-zA-Z0-9_-]+\z/
    BUNNY_UUID_FORMAT = /\A[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}\z/i
    CF_UID_FORMAT = /\A[0-9a-f]{32}\z/i

    FARADAY_TIMEOUT = 15
    FARADAY_OPEN_TIMEOUT = 5

    params do
      attribute :video_id, :string
      attribute :provider, :string

      validates :video_id, presence: true, format: { with: VALID_VIDEO_ID }
    end

    model :deletion_result

    private

    def fetch_deletion_result(params:)
      explicit_provider = normalize_provider(params.provider) ||
        normalize_provider(DeletedVideoTracker.provider_for(params.video_id))

      if explicit_provider.present?
        delete_from_single_provider(explicit_provider, params.video_id)
      else
        delete_with_fallback_candidates(params.video_id)
      end
    end

    def delete_from_single_provider(provider, video_id)
      unless provider_configured?(provider)
        context.fail!(error: I18n.t("video_stream.errors.misconfigured"), status: 422)
      end

      outcome = perform_delete(provider, video_id)
      if outcome[:ok]
        { deleted: true, provider: provider, already_deleted: outcome[:not_found] }
      else
        context.fail!(error: outcome[:error], status: outcome[:status] || 422)
      end
    end

    def delete_with_fallback_candidates(video_id)
      candidates = candidate_providers(video_id).select { |p| provider_configured?(p) }

      if candidates.empty?
        context.fail!(error: I18n.t("video_stream.errors.misconfigured"), status: 422)
      end

      last_error = nil

      candidates.each do |provider|
        outcome = perform_delete(provider, video_id)
        if outcome[:ok] && !outcome[:not_found]
          return { deleted: true, provider: provider, already_deleted: false }
        elsif outcome[:not_found]
          next
        else
          last_error = outcome
        end
      end

      if last_error
        context.fail!(error: last_error[:error], status: last_error[:status] || 422)
      end

      { deleted: true, provider: candidates.first, already_deleted: true }
    end

    def perform_delete(provider, video_id)
      encoded_id = ERB::Util.url_encode(video_id)

      response =
        if provider == "bunny"
          url =
            BUNNY_VIDEO_DELETE_PATH % {
              library_id: SiteSetting.video_stream_bunny_library_id.presence,
              video_id: encoded_id,
            }
          headers = {
            "AccessKey" => SiteSetting.video_stream_bunny_api_key.presence,
            "Accept" => "application/json",
          }
          Faraday.delete(url, nil, headers) do |req|
            req.options.timeout = FARADAY_TIMEOUT
            req.options.open_timeout = FARADAY_OPEN_TIMEOUT
          end
        else
          url =
            CF_VIDEO_DELETE_PATH % {
              account_id: SiteSetting.video_stream_account_id.presence,
              video_id: encoded_id,
            }
          headers = { "Authorization" => "Bearer #{SiteSetting.video_stream_api_token.presence}" }
          Faraday.delete(url, nil, headers) do |req|
            req.options.timeout = FARADAY_TIMEOUT
            req.options.open_timeout = FARADAY_OPEN_TIMEOUT
          end
        end

      if response.status >= 200 && response.status < 300
        { ok: true, not_found: false }
      elsif response.status == 404
        Rails.logger.info(
          "[VideoStream] Video #{video_id} not found on #{provider} during deletion (already removed).",
        )
        { ok: true, not_found: true }
      else
        log_failure(provider, video_id, response.status, response.body)
        {
          ok: false,
          not_found: false,
          status: response.status,
          error: "Failed to delete video on #{provider} (status=#{response.status})",
        }
      end
    rescue Faraday::Error => error
      log_exception(provider, video_id, error)
      { ok: false, not_found: false, status: 502, error: error.message }
    end

    def candidate_providers(video_id)
      format_hint =
        if video_id.match?(BUNNY_UUID_FORMAT)
          "bunny"
        elsif video_id.match?(CF_UID_FORMAT)
          "cloudflare"
        end

      active_provider = normalize_provider(SiteSetting.video_stream_provider)
      [format_hint, active_provider, "cloudflare", "bunny"].compact.uniq
    end

    def provider_configured?(provider)
      if provider == "bunny"
        SiteSetting.video_stream_bunny_library_id.present? &&
          SiteSetting.video_stream_bunny_api_key.present?
      elsif provider == "cloudflare"
        SiteSetting.video_stream_account_id.present? && SiteSetting.video_stream_api_token.present?
      else
        false
      end
    end

    def normalize_provider(value)
      normalized = value.to_s.strip.downcase
      %w[cloudflare bunny].include?(normalized) ? normalized : nil
    end

    def log_failure(provider, video_id, status, body)
      Rails.logger.error(
        "[VideoStream] Failed to delete #{provider} video #{video_id} (status=#{status}): #{body.to_s.truncate(500)}",
      )
    end

    def log_exception(provider, video_id, error)
      Rails.logger.error(
        "[VideoStream] Delete request for #{provider} video #{video_id} raised #{error.class}: #{error.message}",
      )
    end
  end
end
