# frozen_string_literal: true

require "rails_helper"

RSpec.describe DiscourseVideoStream::DeletedVideoTracker do
  fab!(:user)
  fab!(:admin)

  before do
    SiteSetting.video_stream_enabled = true
    SiteSetting.video_stream_delete_on_post_delete = true
    SiteSetting.video_stream_delete_grace_period_hours = 48
    SiteSetting.video_stream_account_id = "cf-acc"
    SiteSetting.video_stream_api_token = "cf-token"
    SiteSetting.video_stream_bunny_library_id = "12345"
    SiteSetting.video_stream_bunny_api_key = "bunny-key"
  end

  after do
    PluginStoreRow.where(plugin_name: DiscourseVideoStream::PLUGIN_NAME).delete_all
  end

  describe ".extract_videos" do
    it "extracts IDs and optional providers from BBCode and cooked HTML" do
      content = <<~TEXT
        [video-stream id="cf12345"][/video-stream]
        [video-stream id="bunny-uuid-1" provider="bunny"]
        [/video-stream]
        <div class="video-stream-container" data-video-id="html_vid_9"></div>
      TEXT

      expect(described_class.extract_videos(content)).to eq(
        "cf12345" => nil,
        "bunny-uuid-1" => "bunny",
        "html_vid_9" => nil,
      )
    end
  end

  describe "lifecycle and cleanup" do
    it "schedules deletion when a post is deleted and deletes after grace period" do
      video_id = "5d5bc37ffcf54c9b82e996823bffbb81"
      post =
        Fabricate(
          :post,
          user: user,
          raw: "[video-stream id=\"#{video_id}\"][/video-stream]",
        )
      described_class.on_post_created(post)

      PostDestroyer.new(admin, post).destroy

      pending =
        PluginStore.get(
          DiscourseVideoStream::PLUGIN_NAME,
          "#{described_class::PENDING_PREFIX}#{video_id}",
        )
      expect(pending).to be_present

      delete_stub =
        stub_request(
          :delete,
          "https://api.cloudflare.com/client/v4/accounts/cf-acc/stream/#{video_id}",
        ).to_return(status: 200, body: { success: true }.to_json)

      # Still inside 48-hour grace period -> should NOT delete
      freeze_time(47.hours.from_now) do
        described_class.cleanup_expired_deletions!
        expect(delete_stub).not_to have_been_requested
      end

      # Past 48-hour grace period -> should delete
      freeze_time(49.hours.from_now) do
        described_class.cleanup_expired_deletions!
        expect(delete_stub).to have_been_requested
      end

      expect(
        PluginStore.get(
          DiscourseVideoStream::PLUGIN_NAME,
          "#{described_class::PENDING_PREFIX}#{video_id}",
        ),
      ).to be_nil
    end

    it "cancels pending deletion if the post is recovered before grace period expires" do
      video_id = "a1b2c3d4-e5f6-7890-abcd-ef1234567890"
      post =
        Fabricate(
          :post,
          user: user,
          raw: "[video-stream id=\"#{video_id}\"][/video-stream]",
        )
      described_class.on_post_created(post)

      PostDestroyer.new(admin, post).destroy
      expect(
        PluginStore.get(
          DiscourseVideoStream::PLUGIN_NAME,
          "#{described_class::PENDING_PREFIX}#{video_id}",
        ),
      ).to be_present

      PostDestroyer.new(admin, post.reload).recover
      expect(
        PluginStore.get(
          DiscourseVideoStream::PLUGIN_NAME,
          "#{described_class::PENDING_PREFIX}#{video_id}",
        ),
      ).to be_nil
    end

    it "does not delete a video if another active post still references it" do
      video_id = "5d5bc37ffcf54c9b82e996823bffbb82"
      post1 =
        Fabricate(
          :post,
          user: user,
          raw: "[video-stream id=\"#{video_id}\"][/video-stream]",
        )
      Fabricate(
        :post,
        user: user,
        raw: "[video-stream id=\"#{video_id}\"][/video-stream]",
      )

      described_class.on_post_created(post1)
      PostDestroyer.new(admin, post1).destroy

      delete_stub =
        stub_request(
          :delete,
          "https://api.cloudflare.com/client/v4/accounts/cf-acc/stream/#{video_id}",
        ).to_return(status: 200, body: { success: true }.to_json)

      freeze_time(49.hours.from_now) do
        described_class.cleanup_expired_deletions!
      end

      expect(delete_stub).not_to have_been_requested
    end

    it "respects a custom grace period setting" do
      SiteSetting.video_stream_delete_grace_period_hours = 6
      video_id = "a1b2c3d4-e5f6-7890-abcd-ef1234567891"
      post =
        Fabricate(
          :post,
          user: user,
          raw: "[video-stream id=\"#{video_id}\"][/video-stream]",
        )

      PostDestroyer.new(admin, post).destroy

      delete_stub =
        stub_request(
          :delete,
          "https://video.bunnycdn.com/library/12345/videos/#{video_id}",
        ).to_return(status: 200, body: { success: true }.to_json)

      freeze_time(7.hours.from_now) do
        described_class.cleanup_expired_deletions!
      end

      expect(delete_stub).to have_been_requested
    end

    it "bypasses the grace period when a post is permanently deleted after soft deletion" do
      video_id = "5d5bc37ffcf54c9b82e996823bffbb83"
      post =
        Fabricate(
          :post,
          user: user,
          raw: "[video-stream id=\"#{video_id}\"][/video-stream]",
        )
      described_class.on_post_created(post)

      delete_stub =
        stub_request(
          :delete,
          "https://api.cloudflare.com/client/v4/accounts/cf-acc/stream/#{video_id}",
        ).to_return(status: 200, body: { success: true }.to_json)

      # Soft delete -> inside 48h grace period, should not delete yet
      PostDestroyer.new(admin, post).destroy
      described_class.cleanup_expired_deletions!
      expect(delete_stub).not_to have_been_requested

      # Permanently delete -> bypasses grace period on next job run
      PostDestroyer.new(admin, post.reload, force_destroy: true).destroy
      described_class.cleanup_expired_deletions!
      expect(delete_stub).to have_been_requested
    end
  end
end
