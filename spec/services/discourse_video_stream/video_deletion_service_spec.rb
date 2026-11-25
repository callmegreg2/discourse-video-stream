# frozen_string_literal: true

require "rails_helper"

RSpec.describe DiscourseVideoStream::VideoDeletionService do
  let(:account_id) { "cf-account-123" }
  let(:api_token) { "cf-token-xyz" }
  let(:library_id) { "99999" }
  let(:bunny_api_key) { "bunny-secret-key" }

  before do
    SiteSetting.video_stream_enabled = true
    SiteSetting.video_stream_account_id = account_id
    SiteSetting.video_stream_api_token = api_token
    SiteSetting.video_stream_bunny_library_id = library_id
    SiteSetting.video_stream_bunny_api_key = bunny_api_key
  end

  after do
    PluginStoreRow.where(plugin_name: DiscourseVideoStream::PLUGIN_NAME).delete_all
  end

  describe ".call" do
    it "fails validation for invalid video IDs" do
      result = described_class.call(params: { video_id: "../bad-id", provider: "cloudflare" })

      expect(result).to be_failure
    end

    it "deletes a Cloudflare Stream video via DELETE API" do
      video_id = "5d5bc37ffcf54c9b82e996823bffbb81"
      stub_request(
        :delete,
        "https://api.cloudflare.com/client/v4/accounts/#{account_id}/stream/#{video_id}",
      ).with(headers: { "Authorization" => "Bearer #{api_token}" }).to_return(
        status: 200,
        body: { success: true }.to_json,
      )

      result = described_class.call(params: { video_id: video_id, provider: "cloudflare" })

      expect(result).to be_success
      expect(result[:deletion_result]).to include(deleted: true, provider: "cloudflare")
    end

    it "deletes a Bunny.net Stream video via DELETE API" do
      video_id = "a1b2c3d4-e5f6-7890-abcd-ef1234567890"
      stub_request(
        :delete,
        "https://video.bunnycdn.com/library/#{library_id}/videos/#{video_id}",
      ).with(headers: { "AccessKey" => bunny_api_key }).to_return(
        status: 200,
        body: { success: true }.to_json,
      )

      result = described_class.call(params: { video_id: video_id, provider: "bunny" })

      expect(result).to be_success
      expect(result[:deletion_result]).to include(deleted: true, provider: "bunny")
    end

    it "uses stored upload metadata even if active provider setting changed" do
      SiteSetting.video_stream_provider = "bunny"
      video_id = "cf_video_saved_earlier"
      DiscourseVideoStream::DeletedVideoTracker.record_upload(
        video_id: video_id,
        provider: "cloudflare",
      )

      stub =
        stub_request(
          :delete,
          "https://api.cloudflare.com/client/v4/accounts/#{account_id}/stream/#{video_id}",
        ).to_return(status: 200, body: { success: true }.to_json)

      result = described_class.call(params: { video_id: video_id })

      expect(result).to be_success
      expect(stub).to have_been_requested
      expect(result[:deletion_result][:provider]).to eq("cloudflare")
    end

    it "treats 404 responses as already deleted" do
      video_id = "missing_cf_video_123"
      stub_request(
        :delete,
        "https://api.cloudflare.com/client/v4/accounts/#{account_id}/stream/#{video_id}",
      ).to_return(status: 404, body: { success: false }.to_json)

      result = described_class.call(params: { video_id: video_id, provider: "cloudflare" })

      expect(result).to be_success
      expect(result[:deletion_result]).to include(deleted: true, already_deleted: true)
    end

    it "falls back across configured providers when provider is unknown" do
      SiteSetting.video_stream_provider = "cloudflare"
      uuid = "11111111-2222-3333-4444-555555555555"

      bunny_stub =
        stub_request(
          :delete,
          "https://video.bunnycdn.com/library/#{library_id}/videos/#{uuid}",
        ).to_return(status: 200, body: { success: true }.to_json)

      result = described_class.call(params: { video_id: uuid })

      expect(result).to be_success
      expect(bunny_stub).to have_been_requested
      expect(result[:deletion_result][:provider]).to eq("bunny")
    end

    it "fails cleanly when the provider returns a 500 error" do
      video_id = "cf_err_123"
      stub_request(
        :delete,
        "https://api.cloudflare.com/client/v4/accounts/#{account_id}/stream/#{video_id}",
      ).to_return(status: 500, body: "Internal Server Error")

      result = described_class.call(params: { video_id: video_id, provider: "cloudflare" })

      expect(result).to be_failure
    end

    it "fails cleanly on Faraday network exceptions" do
      video_id = "cf_net_err_123"
      stub_request(
        :delete,
        "https://api.cloudflare.com/client/v4/accounts/#{account_id}/stream/#{video_id}",
      ).to_raise(Faraday::ConnectionFailed.new("Connection timed out"))

      result = described_class.call(params: { video_id: video_id, provider: "cloudflare" })

      expect(result).to be_failure
    end
  end
end
