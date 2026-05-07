# frozen_string_literal: true

require 'sinatra/base' unless defined?(Sinatra)
require 'legion/logging'
require 'legion/json'
require 'legion/extensions/apollo/helpers/data_models'

module Legion
  module Extensions
    module Apollo
      class Api < Sinatra::Base
        set :host_authorization, permitted: :any

        class << self
          def stats_payload(now: Time.now)
            return { error: 'apollo_data_not_available' } unless Helpers::DataModels.apollo_entry_available?

            entries = Helpers::DataModels.apollo_entry
            by_status = grouped_counts(entries, :status)
            by_status['active'] = entries.exclude(status: 'archived').count

            stats = {
              total_entries:   entries.count,
              recent_24h:      entries.where { created_at >= (now - 86_400) }.count,
              avg_confidence:  average_confidence(entries),
              by_status:       by_status,
              by_content_type: grouped_counts(entries, :content_type)
            }
            stats[:total_relations] = Helpers::DataModels.apollo_relation.count if Helpers::DataModels.apollo_relation_available?
            stats
          end

          private

          def grouped_counts(entries, column)
            entries.group_and_count(column).all.to_h { |row| [row[column].to_s, row[:count]] }
          end

          def average_confidence(entries)
            avg = entries.avg(:confidence)
            avg&.to_f&.round(3)
          end
        end

        before do
          content_type :json
        end

        helpers do
          include Legion::Logging::Helper
          include Legion::JSON::Helper

          def json_body
            body = request.body.read
            return {} if body.empty?

            json_parse(body)
          rescue Legion::JSON::ParseError => e
            handle_exception(e, level: :warn, operation: 'apollo.api.json_body')
            halt 400, json_dump(error: "invalid JSON: #{e.message}")
          end

          def runner
            @runner ||= begin
              obj = Object.new
              obj.extend(Runners::Knowledge)
              obj
            end
          end

          def expertise_runner
            @expertise_runner ||= begin
              obj = Object.new
              obj.extend(Runners::Expertise)
              obj
            end
          end
        end

        # Health check
        get '/api/apollo/health' do
          available = Helpers::DataModels.apollo_entry_available?
          json_dump(status: available ? 'ok' : 'degraded', data_available: available)
        end

        # Query knowledge (semantic search)
        post '/api/apollo/query' do
          req = json_body
          halt 400, json_dump(error: 'query is required') unless req[:query]

          query_options = {
            query:          req[:query],
            limit:          req[:limit] || 10,
            min_confidence: req[:min_confidence] || 0.3,
            tags:           req[:tags],
            domain:         req[:domain],
            agent_id:       req[:agent_id] || 'api'
          }
          query_options[:status] = req[:status] if req.key?(:status)

          result = runner.handle_query(**query_options)
          status result[:success] ? 200 : 500
          json_dump(result)
        end

        # Ingest knowledge
        post '/api/apollo/ingest' do
          req = json_body
          halt 400, json_dump(error: 'content is required') unless req[:content]
          halt 400, json_dump(error: 'content_type is required') unless req[:content_type]

          result = runner.handle_ingest(
            content:          req[:content],
            content_type:     req[:content_type],
            tags:             req[:tags] || [],
            source_agent:     req[:source_agent] || 'api',
            source_provider:  req[:source_provider],
            source_channel:   req[:source_channel],
            knowledge_domain: req[:knowledge_domain],
            context:          req[:context] || {}
          )
          status result[:success] ? 201 : 500
          json_dump(result)
        end

        # Graph traversal
        post '/api/apollo/traverse' do
          req = json_body
          halt 400, json_dump(error: 'entry_id is required') unless req[:entry_id]

          result = runner.handle_traverse(
            entry_id:       req[:entry_id],
            depth:          req[:depth] || 2,
            relation_types: req[:relation_types],
            agent_id:       req[:agent_id] || 'api'
          )
          status result[:success] ? 200 : 500
          json_dump(result)
        end

        # Retrieve relevant (GAIA-compatible)
        post '/api/apollo/retrieve' do
          req = json_body
          halt 400, json_dump(error: 'query is required') unless req[:query]

          result = runner.retrieve_relevant(
            query:          req[:query],
            limit:          req[:limit] || 5,
            min_confidence: req[:min_confidence] || 0.3,
            tags:           req[:tags],
            domain:         req[:domain]
          )
          status result[:success] ? 200 : 500
          json_dump(result)
        end

        # Deprecate entry
        post '/api/apollo/entries/:id/deprecate' do
          result = runner.deprecate_entry(
            entry_id: params[:id],
            reason:   json_body[:reason] || 'deprecated via API'
          )
          json_dump(result)
        end

        # Domains at risk — must be declared before /:agent_id to avoid routing conflict
        get '/api/apollo/expertise/at-risk' do
          result = expertise_runner.domains_at_risk
          json_dump(result)
        end

        # Expertise for an agent
        get '/api/apollo/expertise/:agent_id' do
          result = expertise_runner.agent_profile(agent_id: params[:agent_id])
          json_dump(result)
        end

        # Statistics
        get '/api/apollo/stats' do
          json_dump(self.class.stats_payload)
        end
      end
    end
  end
end
