# frozen_string_literal: true

# name: discourse-video-stream
# about: Integrates Cloudflare and Bunny.net Video Stream for video uploads and playback in Discourse.
# meta_topic_id: TODO
# version: 0.0.18
# authors: dthirdfatpig
# url: https://github.com/dthirdfatpig/discourse-video-stream
# required_version: 2.7.0

enabled_site_setting :video_stream_enabled

# Cloudflare Stream API settings
register_asset "stylesheets/common/video-stream.scss"

module ::DiscourseVideoStream
  PLUGIN_NAME = "discourse-video-stream"
end

require_relative "lib/discourse_video_stream/engine"

def humanized_name
  "Bunny.net and Cloudflare Video Stream"
end

after_initialize do
  register_svg_icon("video")
  register_svg_icon("tower-broadcast")

  on(:post_created) do |post, _opts, _user|
    DiscourseVideoStream::DeletedVideoTracker.on_post_created(post) if SiteSetting.video_stream_enabled
  end

  on(:post_edited) do |post, _topic_changed, revisor|
    if SiteSetting.video_stream_enabled
      DiscourseVideoStream::DeletedVideoTracker.on_post_edited(post, revisor)
    end
  end

  on(:post_destroyed) do |post, opts, _user|
    DiscourseVideoStream::DeletedVideoTracker.on_post_destroyed(post, opts)
  end

  on(:post_recovered) do |post, _opts, _user|
    DiscourseVideoStream::DeletedVideoTracker.on_post_recovered(post) if SiteSetting.video_stream_enabled
  end

  on(:topic_destroyed) do |topic, _user|
    DiscourseVideoStream::DeletedVideoTracker.on_topic_destroyed(topic)
  end

  on(:topic_recovered) do |topic, _user|
    DiscourseVideoStream::DeletedVideoTracker.on_topic_recovered(topic) if SiteSetting.video_stream_enabled
  end
end
