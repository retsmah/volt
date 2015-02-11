require 'volt/models/persistors/store'
require 'volt/models/persistors/query/query_listener_pool'
require 'volt/models/persistors/store_state'

module Volt
  module Persistors
    class ArrayStore < Store
      include StoreState

      @@query_pool = QueryListenerPool.new

      attr_reader :model, :root_dep

      def self.query_pool
        @@query_pool
      end

      def initialize(model, tasks = nil)
        super

        # The listener event counter keeps track of how many things are listening
        # on this model and loads/unloads data when in use.
        @listener_event_counter = EventCounter.new(
          -> { load_data },
          -> { stop_listening }
        )

        # The root dependency tracks how many listeners are on the ArrayModel
        @root_dep = Dependency.new(@listener_event_counter.method(:add), @listener_event_counter.method(:remove))

        @query = @model.options[:query]
        @limit = @model.options[:limit]
        @skip = @model.options[:skip]

        @skip = nil if @skip == 0
      end

      # Called when an each binding is listening
      def event_added(event, first, first_for_event)
        # First event, we load the data.
        if first
          puts "Event added"
          @listener_event_counter.remove
        end
      end

      # Called when an each binding stops listening
      def event_removed(event, last, last_for_event)
        # Remove listener where there are no more events on this model
        if last
          puts "event removed"
          @listener_event_counter.add
        end
      end

      # Called by child models to track their listeners
      def listener_added
        puts "ALA"
        @listener_event_counter.add
      end

      # Called by child models to track their listeners
      def listener_removed
        puts "ALR"
        @listener_event_counter.remove
      end

      # Called when an event is removed and we no longer want to keep in
      # sync with the database.
      def stop_listening
        puts "Stop list"
        if @query_listener
          @query_listener.remove_store(self)
          @query_listener = nil
        end

        @state = :dirty
      end

      # Called the first time data is requested from this collection
      def load_data
        puts "LOAD DATA"
        # Don't load data from any queried
        if @state == :not_loaded || @state == :dirty
          # puts "Load Data at #{@model.path.inspect} - query: #{@query.inspect} on #{self.inspect}"
          change_state_to :state, :loading

          run_query(@model, @query, @skip, @limit)
        end
      end

      # Clear out the models data, since we're not listening anymore.
      def unload_data
        puts 'Unload Data'
        change_state_to :state, :not_loaded
        @model.clear
      end

      def run_query(model, query = {}, skip = nil, limit = nil)
        @model.clear

        collection = model.path.last
        # Scope to the parent
        if model.path.size > 1
          parent = model.parent

          parent.persistor.ensure_setup if parent.persistor

          if parent && (attrs = parent.attributes) && attrs[:_id].true?
            query[:"#{model.path[-3].singularize}_id"] = attrs[:_id]
          end
        end

        # The full query contains the skip and limit
        full_query = [query, skip, limit]
        @query_listener = @@query_pool.lookup(collection, full_query) do
          # Create if it does not exist
          QueryListener.new(@@query_pool, @tasks, collection, full_query)
        end

        @query_listener.add_store(self)
      end

      # Find can take either a query object, or a block that returns a query object.  Use
      # the block style if you need reactive updating queries
      def find(query = nil, &block)
        # Set a default query if there is no block
        if block
          if query
            fail 'Query should not be passed in to a find if a block is specified'
          end
          query = block
        else
          query ||= {}
        end

        Cursor.new([], @model.options.merge(query: query))
      end

      def limit(limit)
        Cursor.new([], @model.options.merge(limit: limit))
      end

      def skip(skip)
        Cursor.new([], @model.options.merge(skip: skip))
      end

      # Returns a promise that is resolved/rejected when the query is complete.  Any
      # passed block will be passed to the promises then.  Then will be passed the model.
      def then(&block)
        fail 'then must pass a block' unless block
        promise = Promise.new

        promise = promise.then(&block)

        if @state == :loaded
          promise.resolve(@model)
        else
          comp = -> do
            puts "CHECK STATE: #{@state}"
            if state == :loaded
              puts "LOADED----"

              promise.resolve(@model)

              comp.stop
            else
              puts "STATE: #{@state}"
            end

          end.watch!

          # -> { state }.watch_until!(:loaded) do
            # Run when the state is changed to :loaded
            # promise.resolve(@model)
          # end
        end

        promise
      end

      # Called from backend
      def add(index, data)
        $loading_models = true

        data_id = data['_id'] || data[:_id]

        # Don't add if the model is already in the ArrayModel
        unless @model.array.find { |v| v._id == data_id }
          # Find the existing model, or create one
          new_model = @@identity_map.find(data_id) do
            new_options = @model.options.merge(path: @model.path + [:[]], parent: @model)
            @model.new_model(data, new_options, :loaded)
          end

          @model.insert(index, new_model)
        end

        $loading_models = false
      end

      def remove(ids)
        $loading_models = true
        ids.each do |id|
          # TODO: optimize this delete so we don't need to loop
          @model.each_with_index do |model, index|
            if model._id == id
              del = @model.delete_at(index)
              break
            end
          end
        end

        $loading_models = false
      end

      def channel_name
        @model.path[-1]
      end

      # When a model is added to this collection, we call its "changed"
      # method.  This should trigger a save.
      def added(model, index)
        if model.persistor
          # Tell the persistor it was added, return the promise
          model.persistor.add_to_collection
        end
      end

      def removed(model)
        if model.persistor
          # Tell the persistor it was removed
          model.persistor.remove_from_collection
        end

        if defined?($loading_models) && $loading_models
          return
        else
          StoreTasks.delete(channel_name, model.attributes[:_id])
        end
      end
    end
  end
end
