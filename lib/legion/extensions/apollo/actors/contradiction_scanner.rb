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
              mutex.synchronize { Array.new(queue.size) { queue.pop(true) } }
            end
          end

          def runner_class    = self.class
          def runner_function = 'scan_pending_contradictions'
          def time            = settings[:actors][:contradiction_interval]
          def run_now?        = false
          def use_runner?     = false
          def check_subtask?  = false
          def generate_task?  = false

          def scan_pending_contradictions(**)
            items = self.class.drain
            return { processed: 0, failed: 0 } if items.empty?

            runner = Object.new.extend(Legion::Extensions::Apollo::Runners::Knowledge)
            processed = 0
            failed = 0
            items.each do |item|
              runner.send(:detect_contradictions, item[:entry_id], item[:embedding], item[:content])
              processed += 1
            rescue StandardError => e
              self.class.enqueue(**item)
              failed += 1
              handle_exception(e, level: :error, operation: 'apollo.actor.contradiction_scanner', entry_id: item[:entry_id])
            end
            log.info("Apollo ContradictionScanner.scan_pending_contradictions processed=#{processed} failed=#{failed}")
            { processed: processed, failed: failed }
          end
        end
      end
    end
  end
end
