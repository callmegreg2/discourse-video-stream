# frozen_string_literal: true

module Jobs
  class CleanUpDeletedStreamVideos < ::Jobs::Scheduled
    every 1.hour

    def execute(_args = nil)
      return unless SiteSetting.video_stream_enabled
      return unless SiteSetting.video_stream_delete_on_post_delete

      DiscourseVideoStream::DeletedVideoTracker.cleanup_expired_deletions!
    end
  end
end
