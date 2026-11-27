# frozen_string_literal: true

module DiscourseVideoStream
  class DeletedVideoTracker
    PENDING_PREFIX = "pending_delete:"
    VIDEO_META_PREFIX = "video_meta:"
    POST_VIDEOS_PREFIX = "post_videos:"

    VALID_VIDEO_ID = /\A[a-zA-Z0-9_-]+\z/
    VALID_PROVIDERS = %w[cloudflare bunny].freeze
    MAX_DELETE_ATTEMPTS = 72

    BBCODE_TAG_REGEX = /\[video-stream\b([^\]]*)\]/i
    ATTR_ID_REGEX = /\bid\s*=\s*(?:"([a-zA-Z0-9_-]+)"|'([a-zA-Z0-9_-]+)'|([a-zA-Z0-9_-]+))/i
    ATTR_PROVIDER_REGEX = /\bprovider\s*=\s*(?:"([a-zA-Z]+)"|'([a-zA-Z]+)'|([a-zA-Z]+))/i
    HTML_DIV_REGEX = /<div\b[^>]*\bclass\s*=\s*["'][^"']*\bvideo-stream-container\b[^"']*["'][^>]*>/i
    DATA_VIDEO_ID_REGEX = /\bdata-video-id\s*=\s*["']([a-zA-Z0-9_-]+)["']/i
    DATA_PROVIDER_REGEX = /\bdata-provider\s*=\s*["']([a-zA-Z]+)["']/i

    def self.record_upload(video_id:, provider:)
      return if video_id.blank? || !video_id.to_s.match?(VALID_VIDEO_ID)

      normalized_provider = normalize_provider(provider)
      return if normalized_provider.blank?

      PluginStore.set(
        DiscourseVideoStream::PLUGIN_NAME,
        "#{VIDEO_META_PREFIX}#{video_id}",
        { provider: normalized_provider, created_at: Time.current.iso8601 },
      )
    rescue StandardError => error
      Rails.logger.warn(
        "[VideoStream] Failed to record upload metadata for #{video_id}: #{error.message}",
      )
    end

    def self.provider_for(video_id)
      return nil if video_id.blank?

      meta = PluginStore.get(DiscourseVideoStream::PLUGIN_NAME, "#{VIDEO_META_PREFIX}#{video_id}")
      normalize_provider(meta&.dig("provider"))
    end

    def self.extract_videos(text)
      return {} if text.blank?

      videos = {}

      text.scan(BBCODE_TAG_REGEX) do |match|
        attrs = match[0].to_s
        id_match = attrs.match(ATTR_ID_REGEX)
        next unless id_match

        video_id = id_match[1] || id_match[2] || id_match[3]
        next if video_id.blank? || !video_id.match?(VALID_VIDEO_ID)

        provider_match = attrs.match(ATTR_PROVIDER_REGEX)
        provider = normalize_provider(provider_match&.captures&.compact&.first)
        videos[video_id] ||= provider
      end

      text.scan(HTML_DIV_REGEX) do |tag|
        id_match = tag.match(DATA_VIDEO_ID_REGEX)
        next unless id_match

        video_id = id_match[1]
        next if video_id.blank? || !video_id.match?(VALID_VIDEO_ID)

        provider_match = tag.match(DATA_PROVIDER_REGEX)
        provider = normalize_provider(provider_match&.captures&.first)
        videos[video_id] ||= provider
      end

      videos
    end

    def self.extract_videos_from_post(post, include_cached: true)
      return {} if post.blank?

      combined = +""
      combined << post.raw.to_s << "\n"
      combined << post.cooked.to_s << "\n"

      if post.user_deleted?
        last_revision = post.revisions.order(number: :desc).first
        prev_raw = last_revision&.modifications&.dig("raw", 0)
        combined << prev_raw.to_s << "\n" if prev_raw.present?
      end

      videos = extract_videos(combined)

      if include_cached
        cached = PluginStore.get(DiscourseVideoStream::PLUGIN_NAME, "#{POST_VIDEOS_PREFIX}#{post.id}")
        if cached.is_a?(Array)
          cached.each do |entry|
            next unless entry.is_a?(Hash)

            vid = entry["video_id"]
            next if vid.blank? || !vid.match?(VALID_VIDEO_ID)

            videos[vid] ||= normalize_provider(entry["provider"])
          end
        end
      end

      videos
    end

    def self.on_post_created(post)
      return if post.blank?

      videos = extract_videos_from_post(post, include_cached: false)
      save_post_videos(post.id, videos)
      videos.each_key { |video_id| cancel_deletion(video_id) }
    end

    def self.on_post_edited(post, revisor = nil)
      return if post.blank?
      return if revisor&.opts&.dig(:deleting_post) || post.user_deleted?

      videos = extract_videos_from_post(post, include_cached: false)
      save_post_videos(post.id, videos)
      videos.each_key { |video_id| cancel_deletion(video_id) }
    end

    def self.on_post_destroyed(post, opts = {})
      return if post.blank?
      return unless SiteSetting.video_stream_enabled && SiteSetting.video_stream_delete_on_post_delete

      permanent = permanent_delete?(post, opts)
      videos = extract_videos_from_post(post, include_cached: true)
      videos.each do |video_id, provider|
        schedule_deletion(
          video_id: video_id,
          provider: provider || provider_for(video_id),
          post_id: post.id,
          topic_id: post.topic_id,
          permanent: permanent,
        )
      end

      PluginStore.remove(DiscourseVideoStream::PLUGIN_NAME, "#{POST_VIDEOS_PREFIX}#{post.id}") if post.destroyed?
    end

    def self.on_post_recovered(post)
      return if post.blank?

      videos = extract_videos_from_post(post, include_cached: true)
      save_post_videos(post.id, videos)
      videos.each_key { |video_id| cancel_deletion(video_id) }
    end

    def self.on_topic_destroyed(topic)
      return if topic.blank?
      return unless SiteSetting.video_stream_enabled && SiteSetting.video_stream_delete_on_post_delete

      opts = topic.destroyed? ? { permanent: true } : {}
      Post.with_deleted.where(topic_id: topic.id).find_each { |post| on_post_destroyed(post, opts) }
    end

    def self.on_topic_recovered(topic)
      return if topic.blank?

      Post
        .where(topic_id: topic.id, deleted_at: nil, user_deleted: false)
        .find_each { |post| on_post_recovered(post) }
    end

    def self.schedule_deletion(
      video_id:,
      provider: nil,
      post_id: nil,
      topic_id: nil,
      deleted_at: Time.current,
      permanent: false
    )
      return if video_id.blank? || !video_id.to_s.match?(VALID_VIDEO_ID)

      key = "#{PENDING_PREFIX}#{video_id}"
      existing = PluginStore.get(DiscourseVideoStream::PLUGIN_NAME, key)

      # Preserve the earliest deleted_at timestamp if already pending
      effective_deleted_at =
        if existing.is_a?(Hash) && existing["deleted_at"].present?
          existing["deleted_at"]
        else
          deleted_at.iso8601
        end

      resolved_provider =
        normalize_provider(provider) ||
          normalize_provider(existing&.dig("provider")) ||
          provider_for(video_id)

      effective_permanent =
        permanent == true || (existing.is_a?(Hash) && existing["permanent"] == true)

      payload = {
        video_id: video_id,
        provider: resolved_provider,
        post_id: post_id || existing&.dig("post_id"),
        topic_id: topic_id || existing&.dig("topic_id"),
        deleted_at: effective_deleted_at,
        permanent: effective_permanent,
        attempts: existing&.dig("attempts").to_i,
      }

      PluginStore.set(DiscourseVideoStream::PLUGIN_NAME, key, payload)
      Rails.logger.info(
        "[VideoStream] Scheduled video #{video_id} for deletion (post_id=#{payload[:post_id]}, permanent=#{effective_permanent}).",
      )
    end

    def self.cancel_deletion(video_id)
      return if video_id.blank?

      PluginStore.remove(DiscourseVideoStream::PLUGIN_NAME, "#{PENDING_PREFIX}#{video_id}")
    end

    def self.video_referenced_in_active_post?(video_id)
      return false if video_id.blank? || !video_id.to_s.match?(VALID_VIDEO_ID)

      pattern = "%#{ActiveRecord::Base.sanitize_sql_like(video_id)}%"

      Post
        .joins(:topic)
        .where(deleted_at: nil, user_deleted: false)
        .where(topics: { deleted_at: nil })
        .where("posts.raw ILIKE :q OR posts.cooked ILIKE :q", q: pattern)
        .find_each do |post|
          videos = extract_videos("#{post.raw}\n#{post.cooked}")
          return true if videos.key?(video_id)
        end

      false
    end

    def self.cleanup_expired_deletions!
      return unless SiteSetting.video_stream_enabled
      return unless SiteSetting.video_stream_delete_on_post_delete

      grace_hours = [SiteSetting.video_stream_delete_grace_period_hours.to_i, 0].max
      cutoff = grace_hours.hours.ago
      pending_pattern = "#{ActiveRecord::Base.sanitize_sql_like(PENDING_PREFIX)}%"

      PluginStoreRow
        .where(plugin_name: DiscourseVideoStream::PLUGIN_NAME)
        .where("plugin_store_rows.key LIKE ?", pending_pattern)
        .find_each do |row|
          entry = parse_row_value(row)
          next if entry.blank?

          video_id = entry["video_id"]
          deleted_at = parse_time(entry["deleted_at"])

          if video_id.blank? || deleted_at.nil?
            row.destroy!
            next
          end

          is_permanent = entry["permanent"] == true
          if !is_permanent && deleted_at > cutoff
            Rails.logger.info(
              "[VideoStream] Skipping video #{video_id}: within #{grace_hours}h grace period (deleted_at=#{deleted_at.iso8601}).",
            )
            next
          end

          if video_referenced_in_active_post?(video_id)
            Rails.logger.info(
              "[VideoStream] Cancelling deletion of #{video_id}: still referenced in an active post.",
            )
            cancel_deletion(video_id)
            next
          end

          result =
            VideoDeletionService.call(
              params: {
                video_id: video_id,
                provider: entry["provider"],
              },
            )

          if result.success?
            Rails.logger.info(
              "[VideoStream] Deleted #{result.dig(:deletion_result, :provider)} video #{video_id}.",
            )
            cancel_deletion(video_id)
            PluginStore.remove(DiscourseVideoStream::PLUGIN_NAME, "#{VIDEO_META_PREFIX}#{video_id}")
          else
            attempts = entry["attempts"].to_i + 1
            if attempts >= MAX_DELETE_ATTEMPTS
              Rails.logger.error(
                "[VideoStream] Giving up deleting video #{video_id} after #{attempts} attempts: #{result[:error]}",
              )
              cancel_deletion(video_id)
            else
              entry["attempts"] = attempts
              PluginStore.set(DiscourseVideoStream::PLUGIN_NAME, row.key, entry)
            end
          end
        end
    end

    def self.save_post_videos(post_id, videos)
      return if post_id.blank?

      key = "#{POST_VIDEOS_PREFIX}#{post_id}"
      if videos.blank?
        PluginStore.remove(DiscourseVideoStream::PLUGIN_NAME, key)
      else
        serialized = videos.map { |vid, prov| { video_id: vid, provider: prov } }
        PluginStore.set(DiscourseVideoStream::PLUGIN_NAME, key, serialized)
      end
    end
    private_class_method :save_post_videos

    def self.permanent_delete?(post, opts)
      return true if post.destroyed?
      return false unless opts.is_a?(Hash)

      ActiveModel::Type::Boolean.new.cast(
        opts[:force_destroy] || opts["force_destroy"] || opts[:permanent] || opts["permanent"],
      ) == true
    end
    private_class_method :permanent_delete?

    def self.normalize_provider(value)
      normalized = value.to_s.strip.downcase
      VALID_PROVIDERS.include?(normalized) ? normalized : nil
    end
    private_class_method :normalize_provider

    def self.parse_row_value(row)
      return nil if row.value.blank?

      PluginStore.cast_value(row.type_name, row.value)
    rescue JSON::ParserError
      nil
    end
    private_class_method :parse_row_value

    def self.parse_time(value)
      return nil if value.blank?

      Time.iso8601(value.to_s)
    rescue ArgumentError
      nil
    end
    private_class_method :parse_time
  end
end
