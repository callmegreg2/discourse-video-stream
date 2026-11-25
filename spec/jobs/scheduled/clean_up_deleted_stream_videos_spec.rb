# frozen_string_literal: true

require "rails_helper"

RSpec.describe Jobs::CleanUpDeletedStreamVideos do
  describe "#execute" do
    before do
      SiteSetting.video_stream_enabled = true
      SiteSetting.video_stream_delete_on_post_delete = true
    end

    it "runs cleanup when enabled" do
      allow(DiscourseVideoStream::DeletedVideoTracker).to receive(:cleanup_expired_deletions!)

      described_class.new.execute

      expect(DiscourseVideoStream::DeletedVideoTracker).to have_received(
        :cleanup_expired_deletions!,
      )
    end

    it "skips cleanup when video_stream_delete_on_post_delete is disabled" do
      SiteSetting.video_stream_delete_on_post_delete = false
      allow(DiscourseVideoStream::DeletedVideoTracker).to receive(:cleanup_expired_deletions!)

      described_class.new.execute

      expect(DiscourseVideoStream::DeletedVideoTracker).not_to have_received(
        :cleanup_expired_deletions!,
      )
    end

    it "skips cleanup when video_stream_enabled is false" do
      SiteSetting.video_stream_enabled = false
      allow(DiscourseVideoStream::DeletedVideoTracker).to receive(:cleanup_expired_deletions!)

      described_class.new.execute

      expect(DiscourseVideoStream::DeletedVideoTracker).not_to have_received(
        :cleanup_expired_deletions!,
      )
    end
  end
end
