require 'rubygems'
gem 'dm-core', '>=0.9.2'
require 'dm-core'
require 'solr'

module DataMapper
  module Resource
    def to_solr_document(dirty=false)
      property_list = self.class.properties.select { |key, value| dirty ? self.dirty_attributes.key?(key) : true }
      inferred_fields = {:type => solr_type_name}
      return Solr::Document.new(property_list.inject(inferred_fields) do |accumulator, property|
        if(value = instance_variable_get(property.instance_variable_name))
          if value.kind_of?(Date) #|| value.is_a?(Date)
            value = value.strftime('%Y-%m-%dT%H:%M:%S')+"Z"
          end
          
          # if value.kind_of?(Date)
          #   puts "hello"
          #   value = value.strftime('%FT%TZ')   
          # end
          
          accumulator[property.field] = value
        end
        accumulator
      end)
    end
    
    protected
    def solr_type_name
      self.class.name.downcase
    end
  end
end

module DataMapper
  module Adapters
    class SolrAdapter < AbstractAdapter
      
      def create(resources)
        created = 0
        with_connection do |connection|
          if(connection.add(resources.map{|r| r.to_solr_document}))
            created += 1
          end
        end
        
        created
      end

      def read_many(query)
        results = with_connection do |connection|
          connection.query(*build_request(query))
        end
        
        Collection.new(query) do |collection|
          results.hits.each do |data|
            collection.load(
              query.fields.map { |property| 
                property.typecast(data[property.field.to_s])
              }
            )
          end
        end
        
      end

      def read_one(query)
        results = with_connection do |connection|
          request = build_request(query, :start => 0, :rows => 1)
          connection.query(*request)
        end
        unless(results.total_hits == 0)
          data = results.hits.first
          query.model.load(query.fields.map { |property| 
            # puts "Prop: #{property.field.to_s} Type: #{property.type} Value: #{property.typecast(data[property.field.to_s]).to_s}" 
            property.typecast(data[property.field.to_s]) 
          }, query)
        end
      end

      def update(attributes, query)
        updated = 0
        resources = read_many(query)
        
        resources.each do |resource| 
          updated +=1 if with_connection do |connection|
            connection.update(resource.to_solr_document)
          end 
        end
        updated
      end

      def delete(query)
        deleted = 0
        deleted += 1 if with_connection do |connection|
          connection.delete_by_query(build_request(query).first)
        end

        deleted
      end
      
      protected
      attr_accessor :solr_connection
      
      # Converts the URI's scheme into a parsed HTTP identifier.
      def normalize_uri(uri_or_options)
        if String === uri_or_options
          uri_or_options = Addressable::URI.parse(uri_or_options)
        end
        if Addressable::URI === uri_or_options
          return uri_or_options.normalize
        end

        user = uri_or_options.delete(:username)
        password = uri_or_options.delete(:password)
        host = (uri_or_options.delete(:host) || "")
        port = uri_or_options.delete(:port)
        database = uri_or_options.delete(:database)
        query = uri_or_options.to_a.map { |pair| pair.join('=') }.join('&')
        query = nil if query == ""

        normalized = Addressable::URI.new(
          "http", user, password, host, port, database, query, nil
        )
        
        puts normalized.inspect
        
        return normalized
      end
      
      def build_request(query, options={})
        # puts query.inspect
        query_fragments = []
        query_fragments << "+type:#{query.model.name.downcase}" # (lritter 13/08/2008 09:54): This should be be factored into a method
        
        options.merge!(:rows => query.limit) if query.limit
        options.merge!(:start => query.offset) if query.offset
        
        query_fragments += query.conditions.map { |operator, property, value|
          field = "#{property.field}:"
          case operator
          when :eql   then "+#{field}#{format_value_for_conditions(operator, property, value)}"
          when :not   then "-#{field}#{value}"
          when :gt    then "+#{field}{#{value} TO *}"
          when :gte   then "+#{field}[#{value} TO *]"
          when :lt    then "+#{field}{* TO #{value}}"
          when :lte   then "+#{field}[* TO #{value}]"
          when :in    then "+#{field}(#{value.join(' ')})"
          when :like  then "+#{field}#{value.gsub('%','*')}"
          end
        }
        
        order_fragments = query.order.map do |order|
          {order.property.field => (order.direction == :asc ? :ascending : :descending)}
        end
  
        options.merge!(:sort => order_fragments) unless order_fragments.empty?
      
        [query_fragments.join(' '), options]
      end
      
      def format_value_for_conditions(operator, property, value)
        value.kind_of?(Enumerable) ? "(#{value.to_a.join(' ')})" : value
      end
      
      def solr_commit
        with_connection { |c| c.commit }
      end
      
      def with_connection(&block)
        connection = nil
        begin
          connection = create_connection
          result = block.call(connection)
          return result
        rescue => e
          # (lritter 12/08/2008 16:48): Loggger?
          puts e.to_s
          puts e.backtrace.join("\n")
          raise e
        ensure
          destroy_connection(connection)
        end
      end
      
      def create_connection
        connect_to = uri.dup 
        connect_to.scheme = 'http'
        Solr::Connection.new(connect_to.to_s, :autocommit => :on)
      end
      
      def destroy_connection(connection)
        connection = nil
      end
      
    end
  end
end