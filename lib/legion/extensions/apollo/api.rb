# frozen_string_literal: true

require 'sinatra/base' unless defined?(Sinatra)
require 'json'

module Legion
  module Extensions
    module Apollo
      class Api < Sinatra::Base
        set :host_authorization, permitted: :any

        before do
          content_type :json
        end

        helpers do
          def json_body
            body = request.body.read
            return {} if body.empty?

            ::JSON.parse(body, symbolize_names: true)
          rescue ::JSON::ParserError => e
            halt 400, { error: "invalid JSON: #{e.message}" }.to_json
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
          available = defined?(Legion::Data::Model::ApolloEntry) ? true : false
          { status: available ? 'ok' : 'degraded', data_available: available }.to_json
        end

        # Query knowledge (semantic search)
        post '/api/apollo/query' do
          req = json_body
          halt 400, { error: 'query is required' }.to_json unless req[:query]

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
          result.to_json
        end

        # Ingest knowledge
        post '/api/apollo/ingest' do
          req = json_body
          halt 400, { error: 'content is required' }.to_json unless req[:content]
          halt 400, { error: 'content_type is required' }.to_json unless req[:content_type]

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
          result.to_json
        end

        # Graph traversal
        post '/api/apollo/traverse' do
          req = json_body
          halt 400, { error: 'entry_id is required' }.to_json unless req[:entry_id]

          result = runner.handle_traverse(
            entry_id:       req[:entry_id],
            depth:          req[:depth] || 2,
            relation_types: req[:relation_types],
            agent_id:       req[:agent_id] || 'api'
          )
          status result[:success] ? 200 : 500
          result.to_json
        end

        # Retrieve relevant (GAIA-compatible)
        post '/api/apollo/retrieve' do
          req = json_body
          halt 400, { error: 'query is required' }.to_json unless req[:query]

          result = runner.retrieve_relevant(
            query:          req[:query],
            limit:          req[:limit] || 5,
            min_confidence: req[:min_confidence] || 0.3,
            tags:           req[:tags],
            domain:         req[:domain]
          )
          status result[:success] ? 200 : 500
          result.to_json
        end

        # Deprecate entry
        post '/api/apollo/entries/:id/deprecate' do
          result = runner.deprecate_entry(
            entry_id: params[:id],
            reason:   json_body[:reason] || 'deprecated via API'
          )
          result.to_json
        end

        # Domains at risk — must be declared before /:agent_id to avoid routing conflict
        get '/api/apollo/expertise/at-risk' do
          result = expertise_runner.domains_at_risk
          result.to_json
        end

        # Expertise for an agent
        get '/api/apollo/expertise/:agent_id' do
          result = expertise_runner.agent_profile(agent_id: params[:agent_id])
          result.to_json
        end

        # Statistics
        get '/api/apollo/stats' do
          stats = {}
          if defined?(Legion::Data::Model::ApolloEntry)
            stats[:total_entries] = Legion::Data::Model::ApolloEntry.count
            stats[:by_status]     = Legion::Data::Model::ApolloEntry.group_and_count(:status).all
                                                                    .to_h { |r| [r[:status], r[:count]] }
            stats[:by_content_type] = Legion::Data::Model::ApolloEntry.group_and_count(:content_type).all
                                                                      .to_h { |r| [r[:content_type], r[:count]] }
            stats[:total_relations] = Legion::Data::Model::ApolloRelation.count if defined?(Legion::Data::Model::ApolloRelation)
          else
            stats[:error] = 'apollo_data_not_available'
          end
          stats.to_json
        end
      end
    end
  end
end
