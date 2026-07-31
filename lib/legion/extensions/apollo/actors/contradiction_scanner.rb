# frozen_string_literal: true

require 'legion/extensions/actors/every'
require_relative '../runners/knowledge'

module Legion
  module Extensions
    module Apollo
      module Actor
        class ContradictionScanner < Legion::Extensions::Actors::Every
          include Legion::Settings::Helper
          include Legion::Logging::Helper

          @queue = Queue.new
          @mutex = Mutex.new

          class << self
            attr_reader :queue, :mutex

            def enqueue(entry_id:, embedding:, content:)
              queue.push({ entry_id: entry_id, embedding: embedding, content: content })
            end

            def pending_count
              queue.size
            end

            def drain
              items = []
              items << queue.pop until queue.empty?
              items
            end
          end

          def runner_class    = Legion::Extensions::Apollo::Runners::Knowledge
          def runner_function = 'scan_pending_contradictions'
          def time            = settings[:actors][:contradiction_interval]
          def run_now?        = false
          def use_runner?     = false
          def check_subtask?  = false
          def generate_task?  = false

          def every
            items = self.class.drain
            return if items.empty?

            log.debug("Apollo ContradictionScanner.every processing=#{items.size}")
            runner = Object.new.extend(Legion::Extensions::Apollo::Runners::Knowledge)
            items.each do |item|
              runner.detect_contradictions(item[:entry_id], item[:embedding], item[:content])
            end
            log.info("Apollo ContradictionScanner.every completed=#{items.size}")
          rescue StandardError => e
            handle_exception(e, level: :error, operation: 'apollo.actor.contradiction_scanner')
          end
        end
      end
    end
  end
end
