# frozen_string_literal: true

module DiscourseVideoStream
  class Engine < ::Rails::Engine
    engine_name "discourse_video_stream"
    isolate_namespace DiscourseVideoStream

    scheduled_job_dir = "#{config.root}/app/jobs/scheduled"
    config.to_prepare { Rails.autoloaders.main.eager_load_dir(scheduled_job_dir) }
  end
end
