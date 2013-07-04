#!/usr/bin/env ruby
#
# Genghis v2.3.6
#
# The single-file MongoDB admin app
#
# http://genghisapp.com
#
# @author Justin Hileman <justin@justinhileman.info>
#
module Genghis
  VERSION = "2.3.6"
end
GENGHIS_VERSION = Genghis::VERSION

require 'mongo'
require 'json'

module Genghis
  class JSON
    class << self
      def as_json(object)
        enc(object, Array, Hash, BSON::OrderedHash, Genghis::Models::Query)
      end

      def encode(object)
        as_json(object).to_json
      end

      def decode(str)
        dec(::JSON.parse(str))
      end

      private

      def enc(o, *a)
        o = o.to_s if o.is_a? Symbol
        fail "invalid: #{o.inspect}" unless a.empty? or a.include? o.class
        case o
        when Genghis::Models::Query then enc(o.as_json)
        when Array then o.map { |e| enc(e) }
        when Hash then enc_hash(o.clone)
        when Time then thunk('ISODate', o.strftime('%FT%T%:z'))
        when Regexp then thunk('RegExp', {'$pattern' => o.source, '$flags' => enc_re_flags(o.options)})
        when BSON::ObjectId then thunk('ObjectId', o.to_s)
        when BSON::DBRef then db_ref(o)
        when BSON::Binary then thunk('BinData', {'$subtype' => o.subtype, '$binary' => enc_bin_data(o)})
        else o
        end
      end

      def enc_hash(o)
        o.keys.each { |k| o[k] = enc(o[k]) }
        o
      end

      def thunk(name, value)
        {'$genghisType' => name, '$value' => value }
      end

      def enc_re_flags(opt)
        ((opt & Regexp::MULTILINE != 0) ? 'm' : '') + ((opt & Regexp::IGNORECASE != 0) ? 'i' : '')
      end

      def enc_bin_data(o)
        Base64.strict_encode64(o.to_s)
      end

      def db_ref(o)
        o = o.to_hash
        {'$ref' => o['$ns'], '$id' => enc(o['$id'])}
      end

      def dec(o)
        case o
        when Array then o.map { |e| dec(e) }
        when Hash then
          case o['$genghisType']
          when 'ObjectId' then mongo_object_id o['$value']
          when 'ISODate'  then mongo_iso_date  o['$value']
          when 'RegExp'   then mongo_reg_exp   o['$value']
          when 'BinData'  then mongo_bin_data  o['$value']
          else o.merge(o) { |k, v| dec(v) }
          end
        else o
        end
      end

      def dec_re_flags(flags)
        f = flags || ''
        (f.include?('m') ? Regexp::MULTILINE : 0) | (f.include?('i') ? Regexp::IGNORECASE : 0)
      end

      def mongo_object_id(value)
        value.nil? ? BSON::ObjectId.new : BSON::ObjectId.from_string(value)
      end

      def mongo_iso_date(value)
        value.nil? ? Time.now : Time.at(DateTime.parse(value).strftime('%s').to_i)
      end

      def mongo_reg_exp(value)
        Regexp.new(value['$pattern'], dec_re_flags(value['$flags']))
      end

      def mongo_bin_data(value)
        BSON::Binary.new(Base64.decode64(value['$binary']), value['$subtype'])
      end

    end
  end
end
require 'sinatra'

module Genghis
  class Exception < ::Exception
  end

  class MalformedDocument < Exception
    def http_status; 400 end

    def initialize(msg=nil)
      @msg = msg
    end

    def message
      @msg || 'Malformed document'
    end
  end

  class NotFound < Exception
    def http_status; 404 end

    def message
      'Not found'
    end
  end

  class AlreadyExists < Exception
    def http_status; 400 end
  end

  class ServerNotFound < NotFound
    def initialize(name)
      @name = name
    end

    def message
      "Server '#{@name}' not found"
    end
  end

  class ServerAlreadyExists < AlreadyExists
    def initialize(name)
      @name = name
    end

    def message
      "Server '#{@name}' already exists"
    end
  end

  class DatabaseNotFound < NotFound
    def initialize(server, name)
      @server = server
      @name   = name
    end

    def message
      "Database '#{@name}' not found on '#{@server.name}'"
    end
  end

  class DatabaseAlreadyExists < AlreadyExists
    def initialize(server, name)
      @server = server
      @name   = name
    end

    def message
      "Database '#{@name}' already exists on '#{@server.name}'"
    end
  end


  class CollectionNotFound < NotFound
    def initialize(database, name)
      @database = database
      @name     = name
    end

    def message
      "Collection '#{@name}' not found in '#{@database.name}'"
    end
  end

  class GridFSNotFound < CollectionNotFound
    def message
      "GridFS collection '#{@name}' not found in '#{@database.name}'"
    end
  end

  class CollectionAlreadyExists < AlreadyExists
    def initialize(database, name)
      @database = database
      @name     = name
    end

    def message
      "Collection '#{@name}' already exists in '#{@database.name}'"
    end
  end

  class DocumentNotFound < NotFound
    def initialize(collection, doc_id)
      @collection = collection
      @doc_id     = doc_id
    end

    def message
      "Document '#{@doc_id}' not found in '#{@collection.name}'"
    end
  end

  class GridFileNotFound < DocumentNotFound
    def message
      "GridFS file '#{@doc_id}' not found"
    end
  end
end
require 'base64'

module Genghis
  module Models
    class Collection
      def initialize(collection)
        @collection = collection
      end

      def name
        @collection.name
      end

      def drop!
        @collection.drop
      end

      def insert(data)
        begin
          id = @collection.insert data
        rescue Mongo::OperationFailure => e
          # going out on a limb here and assuming all of these are malformed...
          raise Genghis::MalformedDocument.new(e.result['errmsg'])
        end

        @collection.find_one('_id' => id)
      end

      def remove(doc_id)
        query = {'_id' => thunk_mongo_id(doc_id)}
        raise Genghis::DocumentNotFound.new(self, doc_id) unless @collection.find_one(query)
        @collection.remove query
      end

      def update(doc_id, data)
        begin
          document = @collection.find_and_modify \
            :query  => {'_id' => thunk_mongo_id(doc_id)},
            :update => data,
            :new    => true
        rescue Mongo::OperationFailure => e
          # going out on a limb here and assuming all of these are malformed...
          raise Genghis::MalformedDocument.new(e.result['errmsg'])
        end

        raise Genghis::DocumentNotFound.new(self, doc_id) unless document
        document
      end

      def documents(query={}, page=1, explain=false)
        Query.new(@collection, query, page, explain)
      end

      def [](doc_id)
        doc = @collection.find_one('_id' => thunk_mongo_id(doc_id))
        raise Genghis::DocumentNotFound.new(self, doc_id) unless doc
        doc
      end

      def put_file(data)
        file = data.delete('file') or raise Genghis::MalformedDocument.new 'Missing file.'

        opts = {}
        data.each do |k, v|
          case k
          when 'filename'
            opts[:filename] = v
          when 'metadata'
            opts[:metadata] = v unless v.empty?
          when '_id'
            opts[:_id]      = v
          when 'contentType'
            opts[:content_type] = v
          else
            raise Genghis::MalformedDocument.new "Unexpected property: '#{k}'"
          end
        end

        id = grid.put(decode_file(file), opts)
        self[id]
      end

      def get_file(doc_id)
        begin
          doc = grid.get(thunk_mongo_id(doc_id))
        rescue Mongo::GridFileNotFound
          raise Genghis::GridFileNotFound.new(self, doc_id)
        end

        raise Genghis::DocumentNotFound.new(self, doc_id) unless doc
        raise Genghis::GridFileNotFound.new(self, doc_id) unless is_grid_file?(doc)

        doc
      end

      def delete_file(doc_id)
        begin
          grid.get(thunk_mongo_id(doc_id))
        rescue Mongo::GridFileNotFound
          raise Genghis::GridFileNotFound.new(self, doc_id)
        end

        res = grid.delete(thunk_mongo_id(doc_id))

        raise Genghis::Exception.new res['err'] unless res['ok']
      end

      def as_json(*)
        {
          :id      => @collection.name,
          :name    => @collection.name,
          :count   => @collection.count,
          :indexes => @collection.index_information.values,
          :stats   => @collection.stats,
        }
      end

      def to_json(*)
        as_json.to_json
      end

      private

      def thunk_mongo_id(doc_id)
        if doc_id.is_a? BSON::ObjectId
          doc_id
        elsif (doc_id[0] == '~')
          doc_id = Base64.decode64(doc_id[1..-1])
          ::Genghis::JSON.decode("{\"_id\":#{doc_id}}")['_id']
        else
          doc_id =~ /^[a-f0-9]{24}$/i ? BSON::ObjectId(doc_id) : doc_id
        end
      end

      def is_grid_collection?
        name.end_with? '.files'
      end

      def grid
        Genghis::GridFSNotFound.new(@collection.db, name) unless is_grid_collection?
        @grid ||= Mongo::Grid.new(@collection.db, name.sub(/\.files$/, ''))
      end

      def is_grid_file?(doc)
        !! doc['chunkSize']
      end

      def decode_file(data)
        unless data =~ /^data:[^;]+;base64,/
          raise Genghis::MalformedDocument.new 'File must be a base64 encoded data: URI'
        end

        Base64.strict_decode64(data.sub(/^data:[^;]+;base64,/, '').strip)
      rescue ArgumentError
        raise Genghis::MalformedDocument.new 'File must be a base64 encoded data: URI'
      end
    end
  end
end
module Genghis
  module Models
    class Database
      def initialize(client, name)
        @client = client
        @name   = name
      end

      def name
        database.name
      end

      def drop!
        database.connection.drop_database(database.name)
      end

      def create_collection(coll_name)
        raise Genghis::CollectionAlreadyExists.new(self, coll_name) if database.collection_names.include? coll_name
        database.create_collection coll_name rescue raise Genghis::MalformedDocument.new('Invalid collection name')
        Collection.new(database[coll_name])
      end

      def collections
        @collections ||= database.collections.map { |c| Collection.new(c) unless system_collection?(c) }.compact
      end

      def [](coll_name)
        raise Genghis::CollectionNotFound.new(self, coll_name) unless database.collection_names.include? coll_name
        Collection.new(database[coll_name])
      end

      def as_json(*)
        {
          :id          => database.name,
          :name        => database.name,
          :count       => collections.count,
          :collections => collections.map { |c| c.name },
          :stats       => stats,
        }
      rescue Mongo::InvalidNSName => e
        {
          :id    => @name,
          :name  => @name,
          :error => e.message,
        }
      end

      def to_json(*)
        as_json.to_json
      end

      private

      def database
        @database ||= @client[@name]
      end

      def info
        @info ||= begin
          name = database.name
          database.connection['admin'].command({:listDatabases => true})['databases'].detect do |db|
            db['name'] == name
          end
        end
      end

      def stats
        @stats ||= database.command({:dbStats => true})
      end

      def system_collection?(coll)
        [
          Mongo::DB::SYSTEM_NAMESPACE_COLLECTION,
          Mongo::DB::SYSTEM_INDEX_COLLECTION,
          Mongo::DB::SYSTEM_PROFILE_COLLECTION,
          Mongo::DB::SYSTEM_USER_COLLECTION,
          Mongo::DB::SYSTEM_JS_COLLECTION
        ].include?(coll.name)
      end
    end
  end
end
module Genghis
  module Models
    class Query
      PAGE_LIMIT = 50

      def initialize(collection, query={}, page=1, explain=false)
        @collection = collection
        @page       = page
        @query      = query
        @explain    = explain
      end

      def as_json(*)
        {
          :count     => documents.count,
          :page      => @page,
          :pages     => pages,
          :per_page  => PAGE_LIMIT,
          :offset    => offset,
          :documents => documents.to_a
        }
      end

      def to_json(*)
        as_json.to_json
      end

      private

      def pages
        [0, (documents.count / PAGE_LIMIT.to_f).ceil].max
      end

      def offset
        PAGE_LIMIT * (@page - 1)
      end

      def documents
        return @documents if @documents
        @documents ||= @collection.find(@query, :limit => PAGE_LIMIT, :skip => offset)

        # Explain returns 1 doc but we expose it as a collection with 1 record
        # and a fake ID
        if @explain
          @documents = [@documents.explain()]
          @documents[0]['_id'] = 'explain'
        end

        @documents
      end

    end
  end
end
module Genghis
  module Models
    class Server
      attr_reader   :name
      attr_reader   :dsn
      attr_reader   :error
      attr_accessor :default

      @default = false

      def initialize(dsn)
        dsn = 'mongodb://'+dsn unless dsn.include? '://'

        begin
          dsn, uri = get_dsn_and_uri(extract_extra_options(dsn))

          # name this server something useful
          name = uri.host

          if user = uri.auths.map { |a| a[:username] || a['username'] }.first
            name = "#{user}@#{name}"
          end

          name = "#{name}:#{uri.port}" unless uri.port == 27017

          if db = uri.auths.map { |a| a[:db_name] || a['db_name'] }.first
            unless db == 'admin'
              name = "#{name}/#{db}"
              @db = db
            end
          end

          @name = name
        rescue Mongo::MongoArgumentError
          @error = 'Malformed server DSN'
          @name  = dsn
        end
        @dsn = dsn
      end

      def create_database(db_name)
        raise Genghis::DatabaseAlreadyExists.new(self, db_name) if db_exists? db_name
        begin
          client[db_name]['__genghis_tmp_collection__'].drop
        rescue Mongo::InvalidNSName
          raise Genghis::MalformedDocument.new('Invalid database name')
        end
        Database.new(client, db_name)
      end

      def databases
        info['databases'].map { |db| Database.new(client, db['name']) }
      end

      def [](db_name)
        raise Genghis::DatabaseNotFound.new(self, db_name) unless db_exists? db_name
        Database.new(client, db_name)
      end

      def as_json(*)
        json = {
          :id       => @name,
          :name     => @name,
          :editable => !@default,
        }

        if @error
          json.merge!({:error => @error})
        else
          begin
            client
            info
          rescue Mongo::AuthenticationError => e
            json.merge!({:error => "Authentication error: #{e.message}"})
          rescue Mongo::ConnectionFailure => e
            json.merge!({:error => "Connection error: #{e.message}"})
          rescue Mongo::OperationFailure => e
            json.merge!({:error => "Connection error: #{e.result['errmsg']}"})
          else
            json.merge!({
              :size      => info['totalSize'].to_i,
              :count     => info['databases'].count,
              :databases => info['databases'].map { |db| db['name'] },
            })
          end
        end

        json
      end

      def to_json(*)
        as_json.to_json
      end

      private

      def get_dsn_and_uri(dsn)
        [dsn, ::Mongo::URIParser.new(dsn)]
      rescue Mongo::MongoArgumentError => e
        raise e unless e.message.include? "MongoDB URI must include username"
        # We'll try one more time...
        dsn = dsn.sub(%r{/?$}, '/admin')
        [dsn, ::Mongo::URIParser.new(dsn)]
      end

      def extract_extra_options(dsn)
        host, opts = dsn.split('?', 2)

        keep  = {}
        @opts = {}
        Rack::Utils.parse_query(opts).each do |opt, value|
          case opt
          when 'replicaSet'
            keep[opt] = value
          when 'connectTimeoutMS'
            unless value =~ /^\d+$/
              raise Mongo::MongoArgumentError.new("Unexpected #{opt} option value: #{value}")
            end
            @opts[:connect_timeout] = (value.to_f / 1000)
          when 'ssl'
            unless value == 'true'
              raise Mongo::MongoArgumentError.new("Unexpected #{opt} option value: #{value}")
            end
            @opts[opt.to_sym] = true
          else
            raise Mongo::MongoArgumentError.new("Unknown option #{opt}")
          end
        end
        opts = Rack::Utils.build_query keep
        opts.empty? ? host : [host, opts].join('?')
      end

      def client
        @client ||= Mongo::MongoClient.from_uri(@dsn, {:connect_timeout => 1, :w => 1}.merge(@opts))
      rescue OpenSSL::SSL::SSLError => e
        raise Mongo::ConnectionFailure.new('SSL connection error')
      rescue StandardError => e
        raise Mongo::ConnectionFailure.new(e.message)
      end

      def info
        @info ||= begin
          if @db.nil?
            client['admin'].command({:listDatabases => true})
          else
            stats = client[@db].command(:dbStats => true)
            {
              'databases' => [{'name' => @db}],
              'totalSize' => stats['fileSize']
            }
          end
        end
      end

      def db_exists?(db_name)
        if @db.nil?
          client.database_names.include? db_name
        else
          @db == db_name
        end
      end
    end
  end
end
require 'mongo'
require 'json'

module Genghis
  module Helpers
    PAGE_LIMIT = 50


    ### Genghis JSON responses ###

    def genghis_json(doc, *args)
      json(::Genghis::JSON.as_json(doc), *args)
    end


    ### Misc request parsing helpers ###

    def query_param
      ::Genghis::JSON.decode(params.fetch('q', '{}'))
    end

    def explain_param
      params.fetch('explain', false) == 'true'
    end

    def page_param
      params.fetch('page', 1).to_i
    end

    def request_json
      @request_json ||= ::JSON.parse request.body.read
    rescue
      raise Genghis::MalformedDocument.new
    end

    def request_genghis_json
      @request_genghis_json ||= ::Genghis::JSON.decode request.body.read
    rescue
      raise Genghis::MalformedDocument.new
    end

    def thunk_mongo_id(id)
      id =~ /^[a-f0-9]{24}$/i ? BSON::ObjectId(id) : id
    end


    ### Seemed like a good place to put this ###

    def server_status_alerts
      require 'rubygems'

      alerts = []

      if check_json_ext?
        msg = <<-MSG.strip.gsub(/\s+/, " ")
          <h4>JSON C extension not found.</h4>
          Falling back to the pure Ruby variant. <code>gem install json</code> for better performance.
        MSG
        alerts << {:level => 'warning', :msg => msg}
      end

      # It would be awesome if we didn't have to resort to this :)
      if Gem::Specification.respond_to? :find_all

        if check_bson_ext?
          Gem.refresh

          installed = Gem::Specification.find_all { |s| s.name == 'mongo' }.map { |s| s.version }.sort.last
          if Gem::Specification.find_all { |s| s.name == 'bson_ext' && s.version == installed }.empty?
            msg = <<-MSG.strip.gsub(/\s+/, " ")
              <h4>MongoDB driver C extension not found.</h4>
              Install this extension for better performance: <code>gem install bson_ext -v #{installed}</code>
            MSG
            alerts << {:level => 'warning', :msg => msg}
          else
            msg = <<-MSG.strip.gsub(/\s+/, " ")
              <h4>Restart required</h4>
              You have recently installed the <tt>bson_ext</tt> extension.
              Run <code>genghisapp&nbsp;--kill</code> then restart <code>genghisapp</code> to use it.
            MSG
            alerts << {:level => 'info', :msg => msg}
          end
        end

        unless ENV['GENGHIS_NO_UPDATE_CHECK']
          require 'open-uri'

          Gem.refresh

          latest    = nil
          installed = Gem::Specification.find_all { |s| s.name == 'genghisapp' }.map { |s| s.version }.sort.last
          running   = Gem::Version.new(Genghis::VERSION.gsub(/[\+_-]/, '.'))

          begin
            open('https://raw.github.com/bobthecow/genghis/master/VERSION') do |f|
              latest = Gem::Version.new(f.read.gsub(/[\+_-]/, '.'))
            end
          rescue
            # do nothing...
          end

          if latest && (installed || running) < latest
            msg = <<-MSG.strip.gsub(/\s+/, " ")
              <h4>A Genghis update is available</h4>
              You are running Genghis version <tt>#{Genghis::VERSION}</tt>. The current version is <tt>#{latest}</tt>.
              Visit <a href="http://genghisapp.com">genghisapp.com</a> for more information.
            MSG
            alerts << {:level => 'warning', :msg => msg}
          elsif installed && running < installed
            msg = <<-MSG.strip.gsub(/\s+/, " ")
              <h4>Restart required</h4>
              You have installed Genghis version <tt>#{installed}</tt> but are still running <tt>#{Genghis::VERSION}</tt>.
              Run <code>genghisapp&nbsp;--kill</code> then restart <code>genghisapp</code>.
            MSG
            alerts << {:level => 'info', :msg => msg}
          end
        end

      end

      alerts
    end


    ### Server management ###

    def servers
      @servers ||= begin
        dsn_list = ::JSON.parse(request.cookies['genghis_rb_servers'] || '[]')
        servers  = default_servers.merge(init_servers(dsn_list))
        servers.empty? ? init_servers(['localhost']) : servers # fall back to 'localhost'
      end
    end

    def default_servers
      @default_servers ||= init_servers((ENV['GENGHIS_SERVERS'] || '').split(';'), :default => true)
    end

    def init_servers(dsn_list, opts={})
      Hash[dsn_list.map { |dsn|
        server = Genghis::Models::Server.new(dsn)
        server.default = opts[:default] || false
        [server.name, server]
      }]
    end

    def add_server(dsn)
      server = Genghis::Models::Server.new(dsn)
      raise Genghis::MalformedDocument.new(server.error) if server.error
      raise Genghis::ServerAlreadyExists.new(server.name) unless servers[server.name].nil?
      servers[server.name] = server
      save_servers
      server
    end

    def remove_server(name)
      raise Genghis::ServerNotFound.new(name) if servers[name].nil?
      @servers.delete(name)
      save_servers
    end

    def save_servers
      dsn_list = servers.collect { |name, server| server.dsn unless server.default }.compact
      response.set_cookie(
        :genghis_rb_servers,
        :path    => '/',
        :value   => dsn_list.to_json,
        :expires => Time.now + 60*60*24*365
      )
    end

    def is_ruby?
      (defined?(RUBY_ENGINE) && RUBY_ENGINE == 'ruby') || !(RUBY_PLATFORM =~ /java/)
    end

    def check_json_ext?
      !ENV['GENGHIS_NO_JSON_CHECK'] && is_ruby? && !defined?(::JSON::Ext)
    end

    def check_bson_ext?
      !ENV['GENGHIS_NO_BSON_CHECK'] && is_ruby? && !defined?(::BSON::BSON_C)
    end

  end
end
require 'sinatra/base'
require 'sinatra/mustache'
require 'sinatra/json'
require 'sinatra/reloader'
require 'sinatra/streaming'
require 'mongo'

module Genghis
  class Server < Sinatra::Base
    # default to 'production' because yeah
    set :environment, :production

    enable :inline_templates

    helpers Sinatra::Streaming

    helpers Sinatra::JSON
    set :json_encoder,      :to_json
    set :json_content_type, :json

    helpers Genghis::Helpers

    def self.version
      Genghis::VERSION
    end


    ### Error handling ###

    helpers do
      def error_response(status, message)
        @status, @message = status, message
        @genghis_version = Genghis::VERSION
        @base_url = request.env['SCRIPT_NAME']
        if request.xhr?
          content_type :json
          error(status, {:error => message, :status => status}.to_json)
        else
          error(status, mustache('error.html.mustache'.intern))
        end
      end
    end

    error 400..599 do
      err = env['sinatra.error']
      error_response(err.respond_to?(:http_status) ? err.http_status : 500, err.message)
    end

    not_found do
      error_response(404, env['sinatra.error'].message.sub(/^Sinatra::NotFound$/, 'Not Found'))
    end


    ### Asset routes ###

    get '/assets/style.css' do
      content_type 'text/css'
      self.class.templates['style.css'.intern].first
    end

    get '/assets/script.js' do
      content_type 'text/javascript'
      self.class.templates['script.js'.intern].first
    end


    ### GridFS handling ###

    get '/servers/:server/databases/:database/collections/:collection/files/:document' do |server, database, collection, document|
      file = servers[server][database][collection].get_file document

      content_type file['contentType'] || 'application/octet-stream'
      attachment   file['filename'] || document

      stream do |out|
        file.each do |chunk|
          out << chunk
        end
      end
    end

    # delete '/servers/:server/databases/:database/collections/:collection/files/:document' do |server, database, collection, document|
    #   # ...
    #   json :success => true
    # end


    ### Default route ###

    get '*' do
      # Unless this is XHR, render index and let the client-side app handle routing
      pass if request.xhr?
      @genghis_version = Genghis::VERSION
      @base_url = request.env['SCRIPT_NAME']
      mustache 'index.html.mustache'.intern
    end


    ### Genghis API ###

    get '/check-status' do
      json :alerts => server_status_alerts
    end

    get '/servers' do
      json servers.values
    end

    post '/servers' do
      json add_server request_json['name']
    end

    get '/servers/:server' do |server|
      raise Genghis::ServerNotFound.new(server) if servers[server].nil?
      json servers[server]
    end

    delete '/servers/:server' do |server|
      remove_server server
      json :success => true
    end

    get '/servers/:server/databases' do |server|
      json servers[server].databases
    end

    post '/servers/:server/databases' do |server|
      json servers[server].create_database request_json['name']
    end

    get '/servers/:server/databases/:database' do |server, database|
      json servers[server][database]
    end

    delete '/servers/:server/databases/:database' do |server, database|
      servers[server][database].drop!
      json :success => true
    end

    get '/servers/:server/databases/:database/collections' do |server, database|
      json servers[server][database].collections
    end

    post '/servers/:server/databases/:database/collections' do |server, database|
      json servers[server][database].create_collection request_json['name']
    end

    get '/servers/:server/databases/:database/collections/:collection' do |server, database, collection|
      json servers[server][database][collection]
    end

    delete '/servers/:server/databases/:database/collections/:collection' do |server, database, collection|
      servers[server][database][collection].drop!
      json :success => true
    end

    get '/servers/:server/databases/:database/collections/:collection/documents' do |server, database, collection|
      genghis_json servers[server][database][collection].documents(query_param, page_param, explain_param)
    end

    post '/servers/:server/databases/:database/collections/:collection/documents' do |server, database, collection|
      document = servers[server][database][collection].insert request_genghis_json
      genghis_json document
    end

    get '/servers/:server/databases/:database/collections/:collection/documents/:document' do |server, database, collection, document|
      genghis_json servers[server][database][collection][document]
    end

    put '/servers/:server/databases/:database/collections/:collection/documents/:document' do |server, database, collection, document|
      document = servers[server][database][collection].update document, request_genghis_json
      genghis_json document
    end

    delete '/servers/:server/databases/:database/collections/:collection/documents/:document' do |server, database, collection, document|
      collection = servers[server][database][collection].remove document
      json :success => true
    end

    post '/servers/:server/databases/:database/collections/:collection/files' do |server, database, collection|
      document = servers[server][database][collection].put_file request_genghis_json
      genghis_json document
    end

    delete '/servers/:server/databases/:database/collections/:collection/files/:document' do |server, database, collection, document|
      servers[server][database][collection].delete_file document
      json :success => true
    end
  end
end


Genghis::Server.run! if __FILE__ == $0

__END__


@@ index.html.mustache


@@ error.html.mustache


@@ style.css
/**
 * Genghis v2.3.6
 *
 * The single-file MongoDB admin app
 *
 * http://genghisapp.com
 *
 * @author Justin Hileman <justin@justinhileman.info>
 */
.CodeMirror{font-family:monospace;height:300px}.CodeMirror-scroll{overflow:auto}.CodeMirror-lines{padding:4px 0}.CodeMirror pre{padding:0 4px}.CodeMirror-scrollbar-filler,.CodeMirror-gutter-filler{background-color:#fff}.CodeMirror-gutters{border-right:1px solid #ddd;background-color:#f7f7f7;white-space:nowrap}.CodeMirror-linenumbers{}.CodeMirror-linenumber{padding:0 3px 0 5px;min-width:20px;text-align:right;color:#999}.CodeMirror div.CodeMirror-cursor{border-left:1px solid black;z-index:3}.CodeMirror div.CodeMirror-secondarycursor{border-left:1px solid silver}.CodeMirror.cm-keymap-fat-cursor div.CodeMirror-cursor{width:auto;border:0;background:#7e7;z-index:1}.CodeMirror div.CodeMirror-cursor.CodeMirror-overwrite{}.cm-tab{display:inline-block}.cm-s-default .cm-keyword{color:#708}.cm-s-default .cm-atom{color:#219}.cm-s-default .cm-number{color:#164}.cm-s-default .cm-def{color:#00f}.cm-s-default .cm-variable{color:#000}.cm-s-default .cm-variable-2{color:#05a}.cm-s-default .cm-variable-3{color:#085}.cm-s-default .cm-property{color:#000}.cm-s-default .cm-operator{color:#000}.cm-s-default .cm-comment{color:#a50}.cm-s-default .cm-string{color:#a11}.cm-s-default .cm-string-2{color:#f50}.cm-s-default .cm-meta{color:#555}.cm-s-default .cm-error{color:red}.cm-s-default .cm-qualifier{color:#555}.cm-s-default .cm-builtin{color:#30a}.cm-s-default .cm-bracket{color:#997}.cm-s-default .cm-tag{color:#170}.cm-s-default .cm-attribute{color:#00c}.cm-s-default .cm-header{color:blue}.cm-s-default .cm-quote{color:#090}.cm-s-default .cm-hr{color:#999}.cm-s-default .cm-link{color:#00c}.cm-negative{color:#d44}.cm-positive{color:#292}.cm-header,.cm-strong{font-weight:700}.cm-em{font-style:italic}.cm-link{text-decoration:underline}.cm-invalidchar{color:red}div.CodeMirror span.CodeMirror-matchingbracket{color:#0f0}div.CodeMirror span.CodeMirror-nonmatchingbracket{color:#f22}.CodeMirror{line-height:1;position:relative;overflow:hidden;background:#fff;color:#000}.CodeMirror-scroll{margin-bottom:-30px;margin-right:-30px;padding-bottom:30px;padding-right:30px;height:100%;outline:none;position:relative}.CodeMirror-sizer{position:relative}.CodeMirror-vscrollbar,.CodeMirror-hscrollbar,.CodeMirror-scrollbar-filler,.CodeMirror-gutter-filler{position:absolute;z-index:6;display:none}.CodeMirror-vscrollbar{right:0;top:0;overflow-x:hidden;overflow-y:scroll}.CodeMirror-hscrollbar{bottom:0;left:0;overflow-y:hidden;overflow-x:scroll}.CodeMirror-scrollbar-filler{right:0;bottom:0}.CodeMirror-gutter-filler{left:0;bottom:0}.CodeMirror-gutters{position:absolute;left:0;top:0;padding-bottom:30px;z-index:3}.CodeMirror-gutter{white-space:normal;height:100%;padding-bottom:30px;margin-bottom:-32px;display:inline-block;*zoom:1;*display:inline}.CodeMirror-gutter-elt{position:absolute;cursor:default;z-index:4}.CodeMirror-lines{cursor:text}.CodeMirror pre{-moz-border-radius:0;-webkit-border-radius:0;border-radius:0;border-width:0;background:transparent;font-family:inherit;font-size:inherit;margin:0;white-space:pre;word-wrap:normal;line-height:inherit;color:inherit;z-index:2;position:relative;overflow:visible}.CodeMirror-wrap pre{word-wrap:break-word;white-space:pre-wrap;word-break:normal}.CodeMirror-linebackground{position:absolute;left:0;right:0;top:0;bottom:0;z-index:0}.CodeMirror-linewidget{position:relative;z-index:2;overflow:auto}.CodeMirror-widget{}.CodeMirror-wrap .CodeMirror-scroll{overflow-x:hidden}.CodeMirror-measure{position:absolute;width:100%;height:0;overflow:hidden;visibility:hidden}.CodeMirror-measure pre{position:static}.CodeMirror div.CodeMirror-cursor{position:absolute;visibility:hidden;border-right:none;width:0}.CodeMirror-focused div.CodeMirror-cursor{visibility:visible}.CodeMirror-selected{background:#d9d9d9}.CodeMirror-focused .CodeMirror-selected{background:#d7d4f0}.cm-searching{background:#ffa;background:rgba(255,255,0,.4)}.CodeMirror span{*vertical-align:text-bottom}@media print{.CodeMirror div.CodeMirror-cursor{visibility:hidden}}kbd,.key{display:inline;display:inline-block;min-width:1em;padding:.2em .3em;font:400 .85em/1 "Lucida Grande",Lucida,Arial,sans-serif;text-align:center;text-decoration:none;-moz-border-radius:.3em;-webkit-border-radius:.3em;border-radius:.3em;border:none;cursor:default;-moz-user-select:none;-webkit-user-select:none;user-select:none}kbd[title],.key[title]{cursor:help}kbd,kbd.dark,.dark-keys kbd,.key,.key.dark,.dark-keys .key{background:#505050;background:-moz-linear-gradient(top,#3c3c3c,#505050);background:-webkit-gradient(linear,left top,left bottom,from(#3c3c3c),to(#505050));color:#fafafa;text-shadow:-1px -1px 0 #464646;-moz-box-shadow:inset 0 0 1px #969696,inset 0 -.05em .4em #505050,0 .1em 0 #1e1e1e,0 .1em .1em rgba(0,0,0,.3);-webkit-box-shadow:inset 0 0 1px #969696,inset 0 -.05em .4em #505050,0 .1em 0 #1e1e1e,0 .1em .1em rgba(0,0,0,.3);box-shadow:inset 0 0 1px #969696,inset 0 -.05em .4em #505050,0 .1em 0 #1e1e1e,0 .1em .1em rgba(0,0,0,.3)}kbd.light,.light-keys kbd,.key.light,.light-keys .key{background:#fafafa;background:-moz-linear-gradient(top,#d2d2d2,#fff);background:-webkit-gradient(linear,left top,left bottom,from(#d2d2d2),to(#fff));color:#323232;text-shadow:0 0 2px#fff;-moz-box-shadow:inset 0 0 1px#fff,inset 0 0 .4em #c8c8c8,0 .1em 0 #828282,0 .11em 0 rgba(0,0,0,.4),0 .1em .11em rgba(0,0,0,.9);-webkit-box-shadow:inset 0 0 1px#fff,inset 0 0 .4em #c8c8c8,0 .1em 0 #828282,0 .11em 0 rgba(0,0,0,.4),0 .1em .11em rgba(0,0,0,.9);box-shadow:inset 0 0 1px#fff,inset 0 0 .4em #c8c8c8,0 .1em 0 #828282,0 .11em 0 rgba(0,0,0,.4),0 .1em .11em rgba(0,0,0,.9)}html,body{background-image:url('data:image/png;base64,iVBORw0KGgoAAAANSUhEUgAAAPwAAADmBAMAAAADyPWpAAAAHlBMVEUAAAAAAAAAAAAAAAD///8AAAAAAAAAAAAAAAAAAAAzn7ZSAAAACnRSTlMEAgEFAAMGBwgJHK6+iAAAAjVJREFUeF7t3TFvEzEYh3EnUQJjoaRzCGS/ChW6UsF+pc0eCSkwVqrUwhcAPjZT38fDKzmKuBvQ858qy/bP9mT57LTcvIu8iHxZP2VVIl8Prrmj0TpyHW1OIf9zXl5eXl5eXl5+uX1Kv41gzuC7rHASnS4bzdOBlk+Rj/AMr2tMFP4lPb2OwhOg24CuWJIheXl5eXl5eXl5ef5cpbtKxoR0ktUs1JyzfYV/xTwLSUdaSfDMfsOSoC9YsgsaMbu3wX8eh5eXl5eXl5eXl+9pn/IU7pD2kfswP1B4l/U5ZfRAR53pXj5GKgl+ly3JOcevLMmQvLy8vLy8vLy8fN/YQNL+d5g/4X+F+Q3+Lv/+HmGe1Ub7LO0U/gEpW5L31JykEx2bl5eXl5eXl5eXr25w7iPsKn/AVxL8njQ+oJNZIdPspBYTqVXzonF9AGg1Di8vLy8vLy8vL89h43wdKUd8VS/byDV8Bj17jBQyZ/gMZNO4KpoUNtfpchxeXl5eXl5eXl5+S7K94pL2VLjJvsqfUpjuP9lqPv8TKckF0vSpU3v7nPGz7KLrm31kQF5eXl5eXl5eXj5/rdMdcVa5OHiruaj4/AIpVQc4/a1qDsnLy8vLy8vLy8t3UNkBZj/Ap/ZFSQPP7vuKwn92+rsEGoOXl5eXl5eXl5fPfywp/133CXzVP3z6fr5rvEo6qx/AR7JO1/D9EYtX6GhIXl5eXl5eXl5eHvM7fPUAvvEviOBn1Jwz5orPav4FxfqDRAI+1ZEAAAAASUVORK5CYII=')}.navbar-search .grippie{background-image:url('data:image/png;base64,iVBORw0KGgoAAAANSUhEUgAAAAEAAAAICAYAAAA4GpVBAAAAFklEQVQIHWPYvXv3f4b/QAAiGBhwcQEh7xt/uRvGTgAAAABJRU5ErkJggg==')}.nav .dropdown,.navbar-search{background-image:url('data:image/png;base64,iVBORw0KGgoAAAANSUhEUgAAAAoAAAAiCAQAAADMxIBtAAABMklEQVQoz2P4z8jA9J+JARUABdj+s2EIerI3cKEJ/2e8zyHE918AXS2njNBFsf+sqIKsfUJJUv9F0Qz4KMSh+EkNzQ3/+Vzktqv/F0IVZNsm46bzXwPdMgkB/Tdm/znQDEjT6DP7r4QqyHJZWdvmvy3Q0yjCUnoW513/i6EK8jcY1bj9N0Uz4KGWktenAHTLZDwctgShOew//2yLqNAfXiiW/eefahUf9t8dVaWcq/Pu4P/KKGF1VVvH+6c/ShD+Fyo06XL7r4emWdb2scd/PmQh9nVqjtb/zVHVCTlqbzD/L4ES9t+kuYx+maOE/X/OcrlC7f8KaJrllB5o/mdHSQ7XheUVURwN0hwotkgOxTFAQR4G8f9SaGlpM1eUILo6NnHuG7zoCYEFmBQ50GMcS6IFAAXadPqU82J+AAAAAElFTkSuQmCC')}section#servers tr.spinning td:first-child{background-image:url('data:image/gif;base64,R0lGODlhEAALAPQAAP///zMzM+Hh4dnZ2e7u7jc3NzMzM1dXV5qamn9/f8fHx05OTm5ubqGhoYKCgsrKylFRUTY2NnFxcerq6t/f3/b29l9fX+Li4vT09MTExLKystTU1PHx8QAAAAAAAAAAACH/C05FVFNDQVBFMi4wAwEAAAAh/hpDcmVhdGVkIHdpdGggYWpheGxvYWQuaW5mbwAh+QQJCwAAACwAAAAAEAALAAAFLSAgjmRpnqSgCuLKAq5AEIM4zDVw03ve27ifDgfkEYe04kDIDC5zrtYKRa2WQgAh+QQJCwAAACwAAAAAEAALAAAFJGBhGAVgnqhpHIeRvsDawqns0qeN5+y967tYLyicBYE7EYkYAgAh+QQJCwAAACwAAAAAEAALAAAFNiAgjothLOOIJAkiGgxjpGKiKMkbz7SN6zIawJcDwIK9W/HISxGBzdHTuBNOmcJVCyoUlk7CEAAh+QQJCwAAACwAAAAAEAALAAAFNSAgjqQIRRFUAo3jNGIkSdHqPI8Tz3V55zuaDacDyIQ+YrBH+hWPzJFzOQQaeavWi7oqnVIhACH5BAkLAAAALAAAAAAQAAsAAAUyICCOZGme1rJY5kRRk7hI0mJSVUXJtF3iOl7tltsBZsNfUegjAY3I5sgFY55KqdX1GgIAIfkECQsAAAAsAAAAABAACwAABTcgII5kaZ4kcV2EqLJipmnZhWGXaOOitm2aXQ4g7P2Ct2ER4AMul00kj5g0Al8tADY2y6C+4FIIACH5BAkLAAAALAAAAAAQAAsAAAUvICCOZGme5ERRk6iy7qpyHCVStA3gNa/7txxwlwv2isSacYUc+l4tADQGQ1mvpBAAIfkECQsAAAAsAAAAABAACwAABS8gII5kaZ7kRFGTqLLuqnIcJVK0DeA1r/u3HHCXC/aKxJpxhRz6Xi0ANAZDWa+kEAA7AAAAAAAAAAAA')}body > section section.spinning > header h2{background-image:url('data:image/gif;base64,R0lGODlhEAALAPQAAN7e3oiIiNHR0c3NzdbW1omJiYiIiJeXl7Ozs6enp8bGxpKSkqCgoLa2tqmpqcjIyJSUlIiIiKKiotXV1dDQ0Nra2pqamtLS0tnZ2cXFxb29vcvLy9jY2AAAAAAAAAAAACH/C05FVFNDQVBFMi4wAwEAAAAh/hpDcmVhdGVkIHdpdGggYWpheGxvYWQuaW5mbwAh+QQJCwAAACwAAAAAEAALAAAFLSAgjmRpnqSgCuLKAq5AEIM4zDVw03ve27ifDgfkEYe04kDIDC5zrtYKRa2WQgAh+QQJCwAAACwAAAAAEAALAAAFJGBhGAVgnqhpHIeRvsDawqns0qeN5+y967tYLyicBYE7EYkYAgAh+QQJCwAAACwAAAAAEAALAAAFNiAgjothLOOIJAkiGgxjpGKiKMkbz7SN6zIawJcDwIK9W/HISxGBzdHTuBNOmcJVCyoUlk7CEAAh+QQJCwAAACwAAAAAEAALAAAFNSAgjqQIRRFUAo3jNGIkSdHqPI8Tz3V55zuaDacDyIQ+YrBH+hWPzJFzOQQaeavWi7oqnVIhACH5BAkLAAAALAAAAAAQAAsAAAUyICCOZGme1rJY5kRRk7hI0mJSVUXJtF3iOl7tltsBZsNfUegjAY3I5sgFY55KqdX1GgIAIfkECQsAAAAsAAAAABAACwAABTcgII5kaZ4kcV2EqLJipmnZhWGXaOOitm2aXQ4g7P2Ct2ER4AMul00kj5g0Al8tADY2y6C+4FIIACH5BAkLAAAALAAAAAAQAAsAAAUvICCOZGme5ERRk6iy7qpyHCVStA3gNa/7txxwlwv2isSacYUc+l4tADQGQ1mvpBAAIfkECQsAAAAsAAAAABAACwAABS8gII5kaZ7kRFGTqLLuqnIcJVK0DeA1r/u3HHCXC/aKxJpxhRz6Xi0ANAZDWa+kEAA7AAAAAAAAAAAA')}article,aside,details,figcaption,figure,footer,header,hgroup,nav,section{display:block}audio,canvas,video{display:inline-block;*display:inline;*zoom:1}audio:not([controls]){display:none}html{font-size:100%;-webkit-text-size-adjust:100%;-ms-text-size-adjust:100%}a:focus{outline:thin dotted #333;outline:5px auto -webkit-focus-ring-color;outline-offset:-2px}a:hover,a:active{outline:0}sub,sup{position:relative;font-size:75%;line-height:0;vertical-align:baseline}sup{top:-0.5em}sub{bottom:-0.25em}img{max-width:100%;width:auto\9;height:auto;vertical-align:middle;border:0;-ms-interpolation-mode:bicubic}#map_canvas img,.google-maps img{max-width:none}button,input,select,textarea{margin:0;font-size:100%;vertical-align:middle}button,input{*overflow:visible;line-height:normal}button::-moz-focus-inner,input::-moz-focus-inner{padding:0;border:0}button,html input[type="button"],input[type="reset"],input[type="submit"]{-webkit-appearance:button;cursor:pointer}label,select,button,input[type="button"],input[type="reset"],input[type="submit"],input[type="radio"],input[type="checkbox"]{cursor:pointer}input[type="search"]{-webkit-box-sizing:content-box;-moz-box-sizing:content-box;box-sizing:content-box;-webkit-appearance:textfield}input[type="search"]::-webkit-search-decoration,input[type="search"]::-webkit-search-cancel-button{-webkit-appearance:none}textarea{overflow:auto;vertical-align:top}@media print{*{text-shadow:none !important;color:#000 !important;background:transparent !important;box-shadow:none !important}a,a:visited{text-decoration:underline}a[href]:after{content:" (" attr(href) ")"}abbr[title]:after{content:" (" attr(title) ")"}.ir a:after,a[href^="javascript:"]:after,a[href^="#"]:after{content:""}pre,blockquote{border:1px solid #999;page-break-inside:avoid}thead{display:table-header-group}tr,img{page-break-inside:avoid}img{max-width:100% !important}@page{margin:.5cm}p,h2,h3{orphans:3;widows:3}h2,h3{page-break-after:avoid}}.clearfix{*zoom:1}.clearfix:before,.clearfix:after{display:table;content:"";line-height:0}.clearfix:after{clear:both}.hide-text{font:0/0 a;color:transparent;text-shadow:none;background-color:transparent;border:0}.input-block-level{display:block;width:100%;min-height:30px;-webkit-box-sizing:border-box;-moz-box-sizing:border-box;box-sizing:border-box}body{margin:0;font-family:"Helvetica Neue",Helvetica,Arial,sans-serif;font-size:14px;line-height:20px;color:#333;background-color:#fff}a{color:#1d8835;text-decoration:none}a:hover,a:focus{color:#10491c;text-decoration:underline}.img-rounded{-webkit-border-radius:6px;-moz-border-radius:6px;border-radius:6px}.img-polaroid{padding:4px;background-color:#fff;border:1px solid #ccc;border:1px solid rgba(0,0,0,0.2);-webkit-box-shadow:0 1px 3px rgba(0,0,0,0.1);-moz-box-shadow:0 1px 3px rgba(0,0,0,0.1);box-shadow:0 1px 3px rgba(0,0,0,0.1)}.img-circle{-webkit-border-radius:500px;-moz-border-radius:500px;border-radius:500px}.row{margin-left:-20px;*zoom:1}.row:before,.row:after{display:table;content:"";line-height:0}.row:after{clear:both}[class*="span"]{float:left;min-height:1px;margin-left:20px}.container,.navbar-static-top .container,.navbar-fixed-top .container,.navbar-fixed-bottom .container{width:940px}.span12{width:940px}.span11{width:860px}.span10{width:780px}.span9{width:700px}.span8{width:620px}.span7{width:540px}.span6{width:460px}.span5{width:380px}.span4{width:300px}.span3{width:220px}.span2{width:140px}.span1{width:60px}.offset12{margin-left:980px}.offset11{margin-left:900px}.offset10{margin-left:820px}.offset9{margin-left:740px}.offset8{margin-left:660px}.offset7{margin-left:580px}.offset6{margin-left:500px}.offset5{margin-left:420px}.offset4{margin-left:340px}.offset3{margin-left:260px}.offset2{margin-left:180px}.offset1{margin-left:100px}.row-fluid{width:100%;*zoom:1}.row-fluid:before,.row-fluid:after{display:table;content:"";line-height:0}.row-fluid:after{clear:both}.row-fluid [class*="span"]{display:block;width:100%;min-height:30px;-webkit-box-sizing:border-box;-moz-box-sizing:border-box;box-sizing:border-box;float:left;margin-left:2.127659574468085%;*margin-left:2.074468085106383%}.row-fluid [class*="span"]:first-child{margin-left:0}.row-fluid .controls-row [class*="span"] + [class*="span"]{margin-left:2.127659574468085%}.row-fluid .span12{width:100%;*width:99.94680851063829%}.row-fluid .span11{width:91.48936170212765%;*width:91.43617021276594%}.row-fluid .span10{width:82.97872340425532%;*width:82.92553191489361%}.row-fluid .span9{width:74.46808510638297%;*width:74.41489361702126%}.row-fluid .span8{width:65.95744680851064%;*width:65.90425531914893%}.row-fluid .span7{width:57.44680851063829%;*width:57.39361702127659%}.row-fluid .span6{width:48.93617021276595%;*width:48.88297872340425%}.row-fluid .span5{width:40.42553191489362%;*width:40.37234042553192%}.row-fluid .span4{width:31.914893617021278%;*width:31.861702127659576%}.row-fluid .span3{width:23.404255319148934%;*width:23.351063829787233%}.row-fluid .span2{width:14.893617021276595%;*width:14.840425531914894%}.row-fluid .span1{width:6.382978723404255%;*width:6.329787234042553%}.row-fluid .offset12{margin-left:104.25531914893617%;*margin-left:104.14893617021275%}.row-fluid .offset12:first-child{margin-left:102.12765957446808%;*margin-left:102.02127659574467%}.row-fluid .offset11{margin-left:95.74468085106382%;*margin-left:95.6382978723404%}.row-fluid .offset11:first-child{margin-left:93.61702127659574%;*margin-left:93.51063829787232%}.row-fluid .offset10{margin-left:87.23404255319149%;*margin-left:87.12765957446807%}.row-fluid .offset10:first-child{margin-left:85.1063829787234%;*margin-left:84.99999999999999%}.row-fluid .offset9{margin-left:78.72340425531914%;*margin-left:78.61702127659572%}.row-fluid .offset9:first-child{margin-left:76.59574468085106%;*margin-left:76.48936170212764%}.row-fluid .offset8{margin-left:70.2127659574468%;*margin-left:70.10638297872339%}.row-fluid .offset8:first-child{margin-left:68.08510638297872%;*margin-left:67.9787234042553%}.row-fluid .offset7{margin-left:61.70212765957446%;*margin-left:61.59574468085106%}.row-fluid .offset7:first-child{margin-left:59.574468085106375%;*margin-left:59.46808510638297%}.row-fluid .offset6{margin-left:53.191489361702125%;*margin-left:53.085106382978715%}.row-fluid .offset6:first-child{margin-left:51.063829787234035%;*margin-left:50.95744680851063%}.row-fluid .offset5{margin-left:44.68085106382979%;*margin-left:44.57446808510638%}.row-fluid .offset5:first-child{margin-left:42.5531914893617%;*margin-left:42.4468085106383%}.row-fluid .offset4{margin-left:36.170212765957444%;*margin-left:36.06382978723405%}.row-fluid .offset4:first-child{margin-left:34.04255319148936%;*margin-left:33.93617021276596%}.row-fluid .offset3{margin-left:27.659574468085104%;*margin-left:27.5531914893617%}.row-fluid .offset3:first-child{margin-left:25.53191489361702%;*margin-left:25.425531914893618%}.row-fluid .offset2{margin-left:19.148936170212764%;*margin-left:19.04255319148936%}.row-fluid .offset2:first-child{margin-left:17.02127659574468%;*margin-left:16.914893617021278%}.row-fluid .offset1{margin-left:10.638297872340425%;*margin-left:10.53191489361702%}.row-fluid .offset1:first-child{margin-left:8.51063829787234%;*margin-left:8.404255319148938%}[class*="span"].hide,.row-fluid [class*="span"].hide{display:none}[class*="span"].pull-right,.row-fluid [class*="span"].pull-right{float:right}.container{margin-right:auto;margin-left:auto;*zoom:1}.container:before,.container:after{display:table;content:"";line-height:0}.container:after{clear:both}.container-fluid{padding-right:20px;padding-left:20px;*zoom:1}.container-fluid:before,.container-fluid:after{display:table;content:"";line-height:0}.container-fluid:after{clear:both}p{margin:0 0 10px}.lead{margin-bottom:20px;font-size:21px;font-weight:200;line-height:30px}small{font-size:85%}strong{font-weight:700}em{font-style:italic}cite{font-style:normal}.muted{color:#999}a.muted:hover,a.muted:focus{color:#808080}.text-warning{color:#c09853}a.text-warning:hover,a.text-warning:focus{color:#a47e3c}.text-error{color:#b94a48}a.text-error:hover,a.text-error:focus{color:#953b39}.text-info{color:#3a87ad}a.text-info:hover,a.text-info:focus{color:#2d6987}.text-success{color:#468847}a.text-success:hover,a.text-success:focus{color:#356635}.text-left{text-align:left}.text-right{text-align:right}.text-center{text-align:center}h1,h2,h3,h4,h5,h6{margin:10px 0;font-family:inherit;font-weight:700;line-height:20px;color:inherit;text-rendering:optimizelegibility}h1 small,h2 small,h3 small,h4 small,h5 small,h6 small{font-weight:400;line-height:1;color:#999}h1,h2,h3{line-height:40px}h1{font-size:38.5px}h2{font-size:31.5px}h3{font-size:24.5px}h4{font-size:17.5px}h5{font-size:14px}h6{font-size:11.9px}h1 small{font-size:24.5px}h2 small{font-size:17.5px}h3 small{font-size:14px}h4 small{font-size:14px}.page-header{padding-bottom:9px;margin:20px 0 30px;border-bottom:1px solid#eee}ul,ol{padding:0;margin:0 0 10px 25px}ul ul,ul ol,ol ol,ol ul{margin-bottom:0}li{line-height:20px}ul.unstyled,ol.unstyled{margin-left:0;list-style:none}ul.inline,ol.inline{margin-left:0;list-style:none}ul.inline > li,ol.inline > li{display:inline-block;*display:inline;*zoom:1;padding-left:5px;padding-right:5px}dl{margin-bottom:20px}dt,dd{line-height:20px}dt{font-weight:700}dd{margin-left:10px}.dl-horizontal{*zoom:1}.dl-horizontal:before,.dl-horizontal:after{display:table;content:"";line-height:0}.dl-horizontal:after{clear:both}.dl-horizontal dt{float:left;width:160px;clear:left;text-align:right;overflow:hidden;text-overflow:ellipsis;white-space:nowrap}.dl-horizontal dd{margin-left:180px}hr{margin:20px 0;border:0;border-top:1px solid#eee;border-bottom:1px solid#fff}abbr[title],abbr[data-original-title]{cursor:help;border-bottom:1px dotted#999}abbr.initialism{font-size:90%;text-transform:uppercase}blockquote{padding:0 0 0 15px;margin:0 0 20px;border-left:5px solid#eee}blockquote p{margin-bottom:0;font-size:17.5px;font-weight:300;line-height:1.25}blockquote small{display:block;line-height:20px;color:#999}blockquote small:before{content:'\2014 \00A0'}blockquote.pull-right{float:right;padding-right:15px;padding-left:0;border-right:5px solid#eee;border-left:0}blockquote.pull-right p,blockquote.pull-right small{text-align:right}blockquote.pull-right small:before{content:''}blockquote.pull-right small:after{content:'\00A0 \2014'}q:before,q:after,blockquote:before,blockquote:after{content:""}address{display:block;margin-bottom:20px;font-style:normal;line-height:20px}code,pre{padding:0 3px 2px;font-family:Monaco,Menlo,Consolas,"Courier New",monospace;font-size:12px;color:#333;-webkit-border-radius:3px;-moz-border-radius:3px;border-radius:3px}code{padding:2px 4px;color:#d14;background-color:#f7f7f9;border:1px solid #e1e1e8;white-space:nowrap}pre{display:block;padding:9.5px;margin:0 0 10px;font-size:13px;line-height:20px;word-break:break-all;word-wrap:break-word;white-space:pre;white-space:pre-wrap;background-color:#f5f5f5;border:1px solid #ccc;border:1px solid rgba(0,0,0,0.15);-webkit-border-radius:4px;-moz-border-radius:4px;border-radius:4px}pre.prettyprint{margin-bottom:20px}pre code{padding:0;color:inherit;white-space:pre;white-space:pre-wrap;background-color:transparent;border:0}.pre-scrollable{max-height:340px;overflow-y:scroll}form{margin:0 0 20px}fieldset{padding:0;margin:0;border:0}legend{display:block;width:100%;padding:0;margin-bottom:20px;font-size:21px;line-height:40px;color:#333;border:0;border-bottom:1px solid #e5e5e5}legend small{font-size:15px;color:#999}label,input,button,select,textarea{font-size:14px;font-weight:400;line-height:20px}input,button,select,textarea{font-family:"Helvetica Neue",Helvetica,Arial,sans-serif}label{display:block;margin-bottom:5px}select,textarea,input[type="text"],input[type="password"],input[type="datetime"],input[type="datetime-local"],input[type="date"],input[type="month"],input[type="time"],input[type="week"],input[type="number"],input[type="email"],input[type="url"],input[type="search"],input[type="tel"],input[type="color"],.uneditable-input{display:inline-block;height:20px;padding:4px 6px;margin-bottom:10px;font-size:14px;line-height:20px;color:#555;-webkit-border-radius:4px;-moz-border-radius:4px;border-radius:4px;vertical-align:middle}input,textarea,.uneditable-input{width:206px}textarea{height:auto}textarea,input[type="text"],input[type="password"],input[type="datetime"],input[type="datetime-local"],input[type="date"],input[type="month"],input[type="time"],input[type="week"],input[type="number"],input[type="email"],input[type="url"],input[type="search"],input[type="tel"],input[type="color"],.uneditable-input{background-color:#fff;border:1px solid#ccc;-webkit-box-shadow:inset 0 1px 1px rgba(0,0,0,0.075);-moz-box-shadow:inset 0 1px 1px rgba(0,0,0,0.075);box-shadow:inset 0 1px 1px rgba(0,0,0,0.075);-webkit-transition:border linear .2s,box-shadow linear .2s;-moz-transition:border linear .2s,box-shadow linear .2s;-o-transition:border linear .2s,box-shadow linear .2s;transition:border linear .2s,box-shadow linear .2s}textarea:focus,input[type="text"]:focus,input[type="password"]:focus,input[type="datetime"]:focus,input[type="datetime-local"]:focus,input[type="date"]:focus,input[type="month"]:focus,input[type="time"]:focus,input[type="week"]:focus,input[type="number"]:focus,input[type="email"]:focus,input[type="url"]:focus,input[type="search"]:focus,input[type="tel"]:focus,input[type="color"]:focus,.uneditable-input:focus{border-color:rgba(82,168,236,0.8);outline:0;outline:thin dotted \9;-webkit-box-shadow:inset 0 1px 1px rgba(0,0,0,.075),0 0 8px rgba(82,168,236,.6);-moz-box-shadow:inset 0 1px 1px rgba(0,0,0,.075),0 0 8px rgba(82,168,236,.6);box-shadow:inset 0 1px 1px rgba(0,0,0,.075),0 0 8px rgba(82,168,236,.6)}input[type="radio"],input[type="checkbox"]{margin:4px 0 0;*margin-top:0;margin-top:1px \9;line-height:normal}input[type="file"],input[type="image"],input[type="submit"],input[type="reset"],input[type="button"],input[type="radio"],input[type="checkbox"]{width:auto}select,input[type="file"]{height:30px;*margin-top:4px;line-height:30px}select{width:220px;border:1px solid#ccc;background-color:#fff}select[multiple],select[size]{height:auto}select:focus,input[type="file"]:focus,input[type="radio"]:focus,input[type="checkbox"]:focus{outline:thin dotted #333;outline:5px auto -webkit-focus-ring-color;outline-offset:-2px}.uneditable-input,.uneditable-textarea{color:#999;background-color:#fcfcfc;border-color:#ccc;-webkit-box-shadow:inset 0 1px 2px rgba(0,0,0,0.025);-moz-box-shadow:inset 0 1px 2px rgba(0,0,0,0.025);box-shadow:inset 0 1px 2px rgba(0,0,0,0.025);cursor:not-allowed}.uneditable-input{overflow:hidden;white-space:nowrap}.uneditable-textarea{width:auto;height:auto}input:-moz-placeholder,textarea:-moz-placeholder{color:#999}input:-ms-input-placeholder,textarea:-ms-input-placeholder{color:#999}input::-webkit-input-placeholder,textarea::-webkit-input-placeholder{color:#999}.radio,.checkbox{min-height:20px;padding-left:20px}.radio input[type="radio"],.checkbox input[type="checkbox"]{float:left;margin-left:-20px}.controls > .radio:first-child,.controls > .checkbox:first-child{padding-top:5px}.radio.inline,.checkbox.inline{display:inline-block;padding-top:5px;margin-bottom:0;vertical-align:middle}.radio.inline + .radio.inline,.checkbox.inline + .checkbox.inline{margin-left:10px}.input-mini{width:60px}.input-small{width:90px}.input-medium{width:150px}.input-large{width:210px}.input-xlarge{width:270px}.input-xxlarge{width:530px}input[class*="span"],select[class*="span"],textarea[class*="span"],.uneditable-input[class*="span"],.row-fluid input[class*="span"],.row-fluid select[class*="span"],.row-fluid textarea[class*="span"],.row-fluid .uneditable-input[class*="span"]{float:none;margin-left:0}.input-append input[class*="span"],.input-append .uneditable-input[class*="span"],.input-prepend input[class*="span"],.input-prepend .uneditable-input[class*="span"],.row-fluid input[class*="span"],.row-fluid select[class*="span"],.row-fluid textarea[class*="span"],.row-fluid .uneditable-input[class*="span"],.row-fluid .input-prepend [class*="span"],.row-fluid .input-append [class*="span"]{display:inline-block}input,textarea,.uneditable-input{margin-left:0}.controls-row [class*="span"] + [class*="span"]{margin-left:20px}input.span12,textarea.span12,.uneditable-input.span12{width:926px}input.span11,textarea.span11,.uneditable-input.span11{width:846px}input.span10,textarea.span10,.uneditable-input.span10{width:766px}input.span9,textarea.span9,.uneditable-input.span9{width:686px}input.span8,textarea.span8,.uneditable-input.span8{width:606px}input.span7,textarea.span7,.uneditable-input.span7{width:526px}input.span6,textarea.span6,.uneditable-input.span6{width:446px}input.span5,textarea.span5,.uneditable-input.span5{width:366px}input.span4,textarea.span4,.uneditable-input.span4{width:286px}input.span3,textarea.span3,.uneditable-input.span3{width:206px}input.span2,textarea.span2,.uneditable-input.span2{width:126px}input.span1,textarea.span1,.uneditable-input.span1{width:46px}.controls-row{*zoom:1}.controls-row:before,.controls-row:after{display:table;content:"";line-height:0}.controls-row:after{clear:both}.controls-row [class*="span"],.row-fluid .controls-row [class*="span"]{float:left}.controls-row .checkbox[class*="span"],.controls-row .radio[class*="span"]{padding-top:5px}input[disabled],select[disabled],textarea[disabled],input[readonly],select[readonly],textarea[readonly]{cursor:not-allowed;background-color:#eee}input[type="radio"][disabled],input[type="checkbox"][disabled],input[type="radio"][readonly],input[type="checkbox"][readonly]{background-color:transparent}.control-group.warning .control-label,.control-group.warning .help-block,.control-group.warning .help-inline{color:#c09853}.control-group.warning .checkbox,.control-group.warning .radio,.control-group.warning input,.control-group.warning select,.control-group.warning textarea{color:#c09853}.control-group.warning input,.control-group.warning select,.control-group.warning textarea{border-color:#c09853;-webkit-box-shadow:inset 0 1px 1px rgba(0,0,0,0.075);-moz-box-shadow:inset 0 1px 1px rgba(0,0,0,0.075);box-shadow:inset 0 1px 1px rgba(0,0,0,0.075)}.control-group.warning input:focus,.control-group.warning select:focus,.control-group.warning textarea:focus{border-color:#a47e3c;-webkit-box-shadow:inset 0 1px 1px rgba(0,0,0,0.075),0 0 6px #dbc59e;-moz-box-shadow:inset 0 1px 1px rgba(0,0,0,0.075),0 0 6px #dbc59e;box-shadow:inset 0 1px 1px rgba(0,0,0,0.075),0 0 6px #dbc59e}.control-group.warning .input-prepend .add-on,.control-group.warning .input-append .add-on{color:#c09853;background-color:#fcf8e3;border-color:#c09853}.control-group.error .control-label,.control-group.error .help-block,.control-group.error .help-inline{color:#b94a48}.control-group.error .checkbox,.control-group.error .radio,.control-group.error input,.control-group.error select,.control-group.error textarea{color:#b94a48}.control-group.error input,.control-group.error select,.control-group.error textarea{border-color:#b94a48;-webkit-box-shadow:inset 0 1px 1px rgba(0,0,0,0.075);-moz-box-shadow:inset 0 1px 1px rgba(0,0,0,0.075);box-shadow:inset 0 1px 1px rgba(0,0,0,0.075)}.control-group.error input:focus,.control-group.error select:focus,.control-group.error textarea:focus{border-color:#953b39;-webkit-box-shadow:inset 0 1px 1px rgba(0,0,0,0.075),0 0 6px #d59392;-moz-box-shadow:inset 0 1px 1px rgba(0,0,0,0.075),0 0 6px #d59392;box-shadow:inset 0 1px 1px rgba(0,0,0,0.075),0 0 6px #d59392}.control-group.error .input-prepend .add-on,.control-group.error .input-append .add-on{color:#b94a48;background-color:#f2dede;border-color:#b94a48}.control-group.success .control-label,.control-group.success .help-block,.control-group.success .help-inline{color:#468847}.control-group.success .checkbox,.control-group.success .radio,.control-group.success input,.control-group.success select,.control-group.success textarea{color:#468847}.control-group.success input,.control-group.success select,.control-group.success textarea{border-color:#468847;-webkit-box-shadow:inset 0 1px 1px rgba(0,0,0,0.075);-moz-box-shadow:inset 0 1px 1px rgba(0,0,0,0.075);box-shadow:inset 0 1px 1px rgba(0,0,0,0.075)}.control-group.success input:focus,.control-group.success select:focus,.control-group.success textarea:focus{border-color:#356635;-webkit-box-shadow:inset 0 1px 1px rgba(0,0,0,0.075),0 0 6px #7aba7b;-moz-box-shadow:inset 0 1px 1px rgba(0,0,0,0.075),0 0 6px #7aba7b;box-shadow:inset 0 1px 1px rgba(0,0,0,0.075),0 0 6px #7aba7b}.control-group.success .input-prepend .add-on,.control-group.success .input-append .add-on{color:#468847;background-color:#dff0d8;border-color:#468847}.control-group.info .control-label,.control-group.info .help-block,.control-group.info .help-inline{color:#3a87ad}.control-group.info .checkbox,.control-group.info .radio,.control-group.info input,.control-group.info select,.control-group.info textarea{color:#3a87ad}.control-group.info input,.control-group.info select,.control-group.info textarea{border-color:#3a87ad;-webkit-box-shadow:inset 0 1px 1px rgba(0,0,0,0.075);-moz-box-shadow:inset 0 1px 1px rgba(0,0,0,0.075);box-shadow:inset 0 1px 1px rgba(0,0,0,0.075)}.control-group.info input:focus,.control-group.info select:focus,.control-group.info textarea:focus{border-color:#2d6987;-webkit-box-shadow:inset 0 1px 1px rgba(0,0,0,0.075),0 0 6px #7ab5d3;-moz-box-shadow:inset 0 1px 1px rgba(0,0,0,0.075),0 0 6px #7ab5d3;box-shadow:inset 0 1px 1px rgba(0,0,0,0.075),0 0 6px #7ab5d3}.control-group.info .input-prepend .add-on,.control-group.info .input-append .add-on{color:#3a87ad;background-color:#d9edf7;border-color:#3a87ad}input:focus:invalid,textarea:focus:invalid,select:focus:invalid{color:#b94a48;border-color:#ee5f5b}input:focus:invalid:focus,textarea:focus:invalid:focus,select:focus:invalid:focus{border-color:#e9322d;-webkit-box-shadow:0 0 6px #f8b9b7;-moz-box-shadow:0 0 6px #f8b9b7;box-shadow:0 0 6px #f8b9b7}.form-actions{padding:19px 20px 20px;margin-top:20px;margin-bottom:20px;background-color:#f5f5f5;border-top:1px solid #e5e5e5;*zoom:1}.form-actions:before,.form-actions:after{display:table;content:"";line-height:0}.form-actions:after{clear:both}.help-block,.help-inline{color:#595959}.help-block{display:block;margin-bottom:10px}.help-inline{display:inline-block;*display:inline;*zoom:1;vertical-align:middle;padding-left:5px}.input-append,.input-prepend{display:inline-block;margin-bottom:10px;vertical-align:middle;font-size:0;white-space:nowrap}.input-append input,.input-prepend input,.input-append select,.input-prepend select,.input-append .uneditable-input,.input-prepend .uneditable-input,.input-append .dropdown-menu,.input-prepend .dropdown-menu,.input-append .popover,.input-prepend .popover{font-size:14px}.input-append input,.input-prepend input,.input-append select,.input-prepend select,.input-append .uneditable-input,.input-prepend .uneditable-input{position:relative;margin-bottom:0;*margin-left:0;vertical-align:top;-webkit-border-radius:0 4px 4px 0;-moz-border-radius:0 4px 4px 0;border-radius:0 4px 4px 0}.input-append input:focus,.input-prepend input:focus,.input-append select:focus,.input-prepend select:focus,.input-append .uneditable-input:focus,.input-prepend .uneditable-input:focus{z-index:2}.input-append .add-on,.input-prepend .add-on{display:inline-block;width:auto;height:20px;min-width:16px;padding:4px 5px;font-size:14px;font-weight:400;line-height:20px;text-align:center;text-shadow:0 1px 0#fff;background-color:#eee;border:1px solid #ccc}.input-append .add-on,.input-prepend .add-on,.input-append .btn,.input-prepend .btn,.input-append .btn-group > .dropdown-toggle,.input-prepend .btn-group > .dropdown-toggle{vertical-align:top;-webkit-border-radius:0;-moz-border-radius:0;border-radius:0}.input-append .active,.input-prepend .active{background-color:#a9dba9;border-color:#46a546}.input-prepend .add-on,.input-prepend .btn{margin-right:-1px}.input-prepend .add-on:first-child,.input-prepend .btn:first-child{-webkit-border-radius:4px 0 0 4px;-moz-border-radius:4px 0 0 4px;border-radius:4px 0 0 4px}.input-append input,.input-append select,.input-append .uneditable-input{-webkit-border-radius:4px 0 0 4px;-moz-border-radius:4px 0 0 4px;border-radius:4px 0 0 4px}.input-append input + .btn-group .btn:last-child,.input-append select + .btn-group .btn:last-child,.input-append .uneditable-input + .btn-group .btn:last-child{-webkit-border-radius:0 4px 4px 0;-moz-border-radius:0 4px 4px 0;border-radius:0 4px 4px 0}.input-append .add-on,.input-append .btn,.input-append .btn-group{margin-left:-1px}.input-append .add-on:last-child,.input-append .btn:last-child,.input-append .btn-group:last-child > .dropdown-toggle{-webkit-border-radius:0 4px 4px 0;-moz-border-radius:0 4px 4px 0;border-radius:0 4px 4px 0}.input-prepend.input-append input,.input-prepend.input-append select,.input-prepend.input-append .uneditable-input{-webkit-border-radius:0;-moz-border-radius:0;border-radius:0}.input-prepend.input-append input + .btn-group .btn,.input-prepend.input-append select + .btn-group .btn,.input-prepend.input-append .uneditable-input + .btn-group .btn{-webkit-border-radius:0 4px 4px 0;-moz-border-radius:0 4px 4px 0;border-radius:0 4px 4px 0}.input-prepend.input-append .add-on:first-child,.input-prepend.input-append .btn:first-child{margin-right:-1px;-webkit-border-radius:4px 0 0 4px;-moz-border-radius:4px 0 0 4px;border-radius:4px 0 0 4px}.input-prepend.input-append .add-on:last-child,.input-prepend.input-append .btn:last-child{margin-left:-1px;-webkit-border-radius:0 4px 4px 0;-moz-border-radius:0 4px 4px 0;border-radius:0 4px 4px 0}.input-prepend.input-append .btn-group:first-child{margin-left:0}input.search-query{padding-right:14px;padding-right:4px \9;padding-left:14px;padding-left:4px \9;margin-bottom:0;-webkit-border-radius:15px;-moz-border-radius:15px;border-radius:15px}.form-search .input-append .search-query,.form-search .input-prepend .search-query{-webkit-border-radius:0;-moz-border-radius:0;border-radius:0}.form-search .input-append .search-query{-webkit-border-radius:14px 0 0 14px;-moz-border-radius:14px 0 0 14px;border-radius:14px 0 0 14px}.form-search .input-append .btn{-webkit-border-radius:0 14px 14px 0;-moz-border-radius:0 14px 14px 0;border-radius:0 14px 14px 0}.form-search .input-prepend .search-query{-webkit-border-radius:0 14px 14px 0;-moz-border-radius:0 14px 14px 0;border-radius:0 14px 14px 0}.form-search .input-prepend .btn{-webkit-border-radius:14px 0 0 14px;-moz-border-radius:14px 0 0 14px;border-radius:14px 0 0 14px}.form-search input,.form-inline input,.form-horizontal input,.form-search textarea,.form-inline textarea,.form-horizontal textarea,.form-search select,.form-inline select,.form-horizontal select,.form-search .help-inline,.form-inline .help-inline,.form-horizontal .help-inline,.form-search .uneditable-input,.form-inline .uneditable-input,.form-horizontal .uneditable-input,.form-search .input-prepend,.form-inline .input-prepend,.form-horizontal .input-prepend,.form-search .input-append,.form-inline .input-append,.form-horizontal .input-append{display:inline-block;*display:inline;*zoom:1;margin-bottom:0;vertical-align:middle}.form-search .hide,.form-inline .hide,.form-horizontal .hide{display:none}.form-search label,.form-inline label,.form-search .btn-group,.form-inline .btn-group{display:inline-block}.form-search .input-append,.form-inline .input-append,.form-search .input-prepend,.form-inline .input-prepend{margin-bottom:0}.form-search .radio,.form-search .checkbox,.form-inline .radio,.form-inline .checkbox{padding-left:0;margin-bottom:0;vertical-align:middle}.form-search .radio input[type="radio"],.form-search .checkbox input[type="checkbox"],.form-inline .radio input[type="radio"],.form-inline .checkbox input[type="checkbox"]{float:left;margin-right:3px;margin-left:0}.control-group{margin-bottom:10px}legend + .control-group{margin-top:20px;-webkit-margin-top-collapse:separate}.form-horizontal .control-group{margin-bottom:20px;*zoom:1}.form-horizontal .control-group:before,.form-horizontal .control-group:after{display:table;content:"";line-height:0}.form-horizontal .control-group:after{clear:both}.form-horizontal .control-label{float:left;width:160px;padding-top:5px;text-align:right}.form-horizontal .controls{*display:inline-block;*padding-left:20px;margin-left:180px;*margin-left:0}.form-horizontal .controls:first-child{*padding-left:180px}.form-horizontal .help-block{margin-bottom:0}.form-horizontal input + .help-block,.form-horizontal select + .help-block,.form-horizontal textarea + .help-block,.form-horizontal .uneditable-input + .help-block,.form-horizontal .input-prepend + .help-block,.form-horizontal .input-append + .help-block{margin-top:10px}.form-horizontal .form-actions{padding-left:180px}table{max-width:100%;background-color:transparent;border-collapse:collapse;border-spacing:0}.table{width:100%;margin-bottom:20px}.table th,.table td{padding:8px;line-height:20px;text-align:left;vertical-align:top;border-top:1px solid#ddd}.table th{font-weight:700}.table thead th{vertical-align:bottom}.table caption + thead tr:first-child th,.table caption + thead tr:first-child td,.table colgroup + thead tr:first-child th,.table colgroup + thead tr:first-child td,.table thead:first-child tr:first-child th,.table thead:first-child tr:first-child td{border-top:0}.table tbody + tbody{border-top:2px solid#ddd}.table .table{background-color:#fff}.table-condensed th,.table-condensed td{padding:4px 5px}.table-bordered{border:1px solid#ddd;border-collapse:separate;*border-collapse:collapse;border-left:0;-webkit-border-radius:4px;-moz-border-radius:4px;border-radius:4px}.table-bordered th,.table-bordered td{border-left:1px solid#ddd}.table-bordered caption + thead tr:first-child th,.table-bordered caption + tbody tr:first-child th,.table-bordered caption + tbody tr:first-child td,.table-bordered colgroup + thead tr:first-child th,.table-bordered colgroup + tbody tr:first-child th,.table-bordered colgroup + tbody tr:first-child td,.table-bordered thead:first-child tr:first-child th,.table-bordered tbody:first-child tr:first-child th,.table-bordered tbody:first-child tr:first-child td{border-top:0}.table-bordered thead:first-child tr:first-child > th:first-child,.table-bordered tbody:first-child tr:first-child > td:first-child,.table-bordered tbody:first-child tr:first-child > th:first-child{-webkit-border-top-left-radius:4px;-moz-border-radius-topleft:4px;border-top-left-radius:4px}.table-bordered thead:first-child tr:first-child > th:last-child,.table-bordered tbody:first-child tr:first-child > td:last-child,.table-bordered tbody:first-child tr:first-child > th:last-child{-webkit-border-top-right-radius:4px;-moz-border-radius-topright:4px;border-top-right-radius:4px}.table-bordered thead:last-child tr:last-child > th:first-child,.table-bordered tbody:last-child tr:last-child > td:first-child,.table-bordered tbody:last-child tr:last-child > th:first-child,.table-bordered tfoot:last-child tr:last-child > td:first-child,.table-bordered tfoot:last-child tr:last-child > th:first-child{-webkit-border-bottom-left-radius:4px;-moz-border-radius-bottomleft:4px;border-bottom-left-radius:4px}.table-bordered thead:last-child tr:last-child > th:last-child,.table-bordered tbody:last-child tr:last-child > td:last-child,.table-bordered tbody:last-child tr:last-child > th:last-child,.table-bordered tfoot:last-child tr:last-child > td:last-child,.table-bordered tfoot:last-child tr:last-child > th:last-child{-webkit-border-bottom-right-radius:4px;-moz-border-radius-bottomright:4px;border-bottom-right-radius:4px}.table-bordered tfoot + tbody:last-child tr:last-child td:first-child{-webkit-border-bottom-left-radius:0;-moz-border-radius-bottomleft:0;border-bottom-left-radius:0}.table-bordered tfoot + tbody:last-child tr:last-child td:last-child{-webkit-border-bottom-right-radius:0;-moz-border-radius-bottomright:0;border-bottom-right-radius:0}.table-bordered caption + thead tr:first-child th:first-child,.table-bordered caption + tbody tr:first-child td:first-child,.table-bordered colgroup + thead tr:first-child th:first-child,.table-bordered colgroup + tbody tr:first-child td:first-child{-webkit-border-top-left-radius:4px;-moz-border-radius-topleft:4px;border-top-left-radius:4px}.table-bordered caption + thead tr:first-child th:last-child,.table-bordered caption + tbody tr:first-child td:last-child,.table-bordered colgroup + thead tr:first-child th:last-child,.table-bordered colgroup + tbody tr:first-child td:last-child{-webkit-border-top-right-radius:4px;-moz-border-radius-topright:4px;border-top-right-radius:4px}.table-striped tbody > tr:nth-child(odd) > td,.table-striped tbody > tr:nth-child(odd) > th{background-color:#f9f9f9}.table-hover tbody tr:hover > td,.table-hover tbody tr:hover > th{background-color:#f5f5f5}table td[class*="span"],table th[class*="span"],.row-fluid table td[class*="span"],.row-fluid table th[class*="span"]{display:table-cell;float:none;margin-left:0}.table td.span1,.table th.span1{float:none;width:44px;margin-left:0}.table td.span2,.table th.span2{float:none;width:124px;margin-left:0}.table td.span3,.table th.span3{float:none;width:204px;margin-left:0}.table td.span4,.table th.span4{float:none;width:284px;margin-left:0}.table td.span5,.table th.span5{float:none;width:364px;margin-left:0}.table td.span6,.table th.span6{float:none;width:444px;margin-left:0}.table td.span7,.table th.span7{float:none;width:524px;margin-left:0}.table td.span8,.table th.span8{float:none;width:604px;margin-left:0}.table td.span9,.table th.span9{float:none;width:684px;margin-left:0}.table td.span10,.table th.span10{float:none;width:764px;margin-left:0}.table td.span11,.table th.span11{float:none;width:844px;margin-left:0}.table td.span12,.table th.span12{float:none;width:924px;margin-left:0}.table tbody tr.success > td{background-color:#dff0d8}.table tbody tr.error > td{background-color:#f2dede}.table tbody tr.warning > td{background-color:#fcf8e3}.table tbody tr.info > td{background-color:#d9edf7}.table-hover tbody tr.success:hover > td{background-color:#d0e9c6}.table-hover tbody tr.error:hover > td{background-color:#ebcccc}.table-hover tbody tr.warning:hover > td{background-color:#faf2cc}.table-hover tbody tr.info:hover > td{background-color:#c4e3f3}[class^="icon-"],[class*=" icon-"]{display:inline-block;width:14px;height:14px;*margin-right:.3em;line-height:14px;vertical-align:text-top;background-image:url("../../vendor/bootstrap/less/../img/glyphicons-halflings.png");background-position:14px 14px;background-repeat:no-repeat;margin-top:1px}.icon-white,.nav-pills > .active > a > [class^="icon-"],.nav-pills > .active > a > [class*=" icon-"],.nav-list > .active > a > [class^="icon-"],.nav-list > .active > a > [class*=" icon-"],.navbar-inverse .nav > .active > a > [class^="icon-"],.navbar-inverse .nav > .active > a > [class*=" icon-"],.dropdown-menu > li > a:hover > [class^="icon-"],.dropdown-menu > li > a:focus > [class^="icon-"],.dropdown-menu > li > a:hover > [class*=" icon-"],.dropdown-menu > li > a:focus > [class*=" icon-"],.dropdown-menu > .active > a > [class^="icon-"],.dropdown-menu > .active > a > [class*=" icon-"],.dropdown-submenu:hover > a > [class^="icon-"],.dropdown-submenu:focus > a > [class^="icon-"],.dropdown-submenu:hover > a > [class*=" icon-"],.dropdown-submenu:focus > a > [class*=" icon-"]{background-image:url("../../vendor/bootstrap/less/../img/glyphicons-halflings-white.png")}.icon-glass{background-position:0 0}.icon-music{background-position:-24px 0}.icon-search{background-position:-48px 0}.icon-envelope{background-position:-72px 0}.icon-heart{background-position:-96px 0}.icon-star{background-position:-120px 0}.icon-star-empty{background-position:-144px 0}.icon-user{background-position:-168px 0}.icon-film{background-position:-192px 0}.icon-th-large{background-position:-216px 0}.icon-th{background-position:-240px 0}.icon-th-list{background-position:-264px 0}.icon-ok{background-position:-288px 0}.icon-remove{background-position:-312px 0}.icon-zoom-in{background-position:-336px 0}.icon-zoom-out{background-position:-360px 0}.icon-off{background-position:-384px 0}.icon-signal{background-position:-408px 0}.icon-cog{background-position:-432px 0}.icon-trash{background-position:-456px 0}.icon-home{background-position:0 -24px}.icon-file{background-position:-24px -24px}.icon-time{background-position:-48px -24px}.icon-road{background-position:-72px -24px}.icon-download-alt{background-position:-96px -24px}.icon-download{background-position:-120px -24px}.icon-upload{background-position:-144px -24px}.icon-inbox{background-position:-168px -24px}.icon-play-circle{background-position:-192px -24px}.icon-repeat{background-position:-216px -24px}.icon-refresh{background-position:-240px -24px}.icon-list-alt{background-position:-264px -24px}.icon-lock{background-position:-287px -24px}.icon-flag{background-position:-312px -24px}.icon-headphones{background-position:-336px -24px}.icon-volume-off{background-position:-360px -24px}.icon-volume-down{background-position:-384px -24px}.icon-volume-up{background-position:-408px -24px}.icon-qrcode{background-position:-432px -24px}.icon-barcode{background-position:-456px -24px}.icon-tag{background-position:0 -48px}.icon-tags{background-position:-25px -48px}.icon-book{background-position:-48px -48px}.icon-bookmark{background-position:-72px -48px}.icon-print{background-position:-96px -48px}.icon-camera{background-position:-120px -48px}.icon-font{background-position:-144px -48px}.icon-bold{background-position:-167px -48px}.icon-italic{background-position:-192px -48px}.icon-text-height{background-position:-216px -48px}.icon-text-width{background-position:-240px -48px}.icon-align-left{background-position:-264px -48px}.icon-align-center{background-position:-288px -48px}.icon-align-right{background-position:-312px -48px}.icon-align-justify{background-position:-336px -48px}.icon-list{background-position:-360px -48px}.icon-indent-left{background-position:-384px -48px}.icon-indent-right{background-position:-408px -48px}.icon-facetime-video{background-position:-432px -48px}.icon-picture{background-position:-456px -48px}.icon-pencil{background-position:0 -72px}.icon-map-marker{background-position:-24px -72px}.icon-adjust{background-position:-48px -72px}.icon-tint{background-position:-72px -72px}.icon-edit{background-position:-96px -72px}.icon-share{background-position:-120px -72px}.icon-check{background-position:-144px -72px}.icon-move{background-position:-168px -72px}.icon-step-backward{background-position:-192px -72px}.icon-fast-backward{background-position:-216px -72px}.icon-backward{background-position:-240px -72px}.icon-play{background-position:-264px -72px}.icon-pause{background-position:-288px -72px}.icon-stop{background-position:-312px -72px}.icon-forward{background-position:-336px -72px}.icon-fast-forward{background-position:-360px -72px}.icon-step-forward{background-position:-384px -72px}.icon-eject{background-position:-408px -72px}.icon-chevron-left{background-position:-432px -72px}.icon-chevron-right{background-position:-456px -72px}.icon-plus-sign{background-position:0 -96px}.icon-minus-sign{background-position:-24px -96px}.icon-remove-sign{background-position:-48px -96px}.icon-ok-sign{background-position:-72px -96px}.icon-question-sign{background-position:-96px -96px}.icon-info-sign{background-position:-120px -96px}.icon-screenshot{background-position:-144px -96px}.icon-remove-circle{background-position:-168px -96px}.icon-ok-circle{background-position:-192px -96px}.icon-ban-circle{background-position:-216px -96px}.icon-arrow-left{background-position:-240px -96px}.icon-arrow-right{background-position:-264px -96px}.icon-arrow-up{background-position:-289px -96px}.icon-arrow-down{background-position:-312px -96px}.icon-share-alt{background-position:-336px -96px}.icon-resize-full{background-position:-360px -96px}.icon-resize-small{background-position:-384px -96px}.icon-plus{background-position:-408px -96px}.icon-minus{background-position:-433px -96px}.icon-asterisk{background-position:-456px -96px}.icon-exclamation-sign{background-position:0 -120px}.icon-gift{background-position:-24px -120px}.icon-leaf{background-position:-48px -120px}.icon-fire{background-position:-72px -120px}.icon-eye-open{background-position:-96px -120px}.icon-eye-close{background-position:-120px -120px}.icon-warning-sign{background-position:-144px -120px}.icon-plane{background-position:-168px -120px}.icon-calendar{background-position:-192px -120px}.icon-random{background-position:-216px -120px;width:16px}.icon-comment{background-position:-240px -120px}.icon-magnet{background-position:-264px -120px}.icon-chevron-up{background-position:-288px -120px}.icon-chevron-down{background-position:-313px -119px}.icon-retweet{background-position:-336px -120px}.icon-shopping-cart{background-position:-360px -120px}.icon-folder-close{background-position:-384px -120px;width:16px}.icon-folder-open{background-position:-408px -120px;width:16px}.icon-resize-vertical{background-position:-432px -119px}.icon-resize-horizontal{background-position:-456px -118px}.icon-hdd{background-position:0 -144px}.icon-bullhorn{background-position:-24px -144px}.icon-bell{background-position:-48px -144px}.icon-certificate{background-position:-72px -144px}.icon-thumbs-up{background-position:-96px -144px}.icon-thumbs-down{background-position:-120px -144px}.icon-hand-right{background-position:-144px -144px}.icon-hand-left{background-position:-168px -144px}.icon-hand-up{background-position:-192px -144px}.icon-hand-down{background-position:-216px -144px}.icon-circle-arrow-right{background-position:-240px -144px}.icon-circle-arrow-left{background-position:-264px -144px}.icon-circle-arrow-up{background-position:-288px -144px}.icon-circle-arrow-down{background-position:-312px -144px}.icon-globe{background-position:-336px -144px}.icon-wrench{background-position:-360px -144px}.icon-tasks{background-position:-384px -144px}.icon-filter{background-position:-408px -144px}.icon-briefcase{background-position:-432px -144px}.icon-fullscreen{background-position:-456px -144px}.dropup,.dropdown{position:relative}.dropdown-toggle{*margin-bottom:-3px}.dropdown-toggle:active,.open .dropdown-toggle{outline:0}.caret{display:inline-block;width:0;height:0;vertical-align:top;border-top:4px solid#000;border-right:4px solid transparent;border-left:4px solid transparent;content:""}.dropdown .caret{margin-top:8px;margin-left:2px}.dropdown-menu{position:absolute;top:100%;left:0;z-index:1000;display:none;float:left;min-width:160px;padding:5px 0;margin:2px 0 0;list-style:none;background-color:#fff;border:1px solid #ccc;border:1px solid rgba(0,0,0,0.2);*border-right-width:2px;*border-bottom-width:2px;-webkit-border-radius:6px;-moz-border-radius:6px;border-radius:6px;-webkit-box-shadow:0 5px 10px rgba(0,0,0,0.2);-moz-box-shadow:0 5px 10px rgba(0,0,0,0.2);box-shadow:0 5px 10px rgba(0,0,0,0.2);-webkit-background-clip:padding-box;-moz-background-clip:padding;background-clip:padding-box}.dropdown-menu.pull-right{right:0;left:auto}.dropdown-menu .divider{*width:100%;height:1px;margin:9px 1px;*margin:-5px 0 5px;overflow:hidden;background-color:#e5e5e5;border-bottom:1px solid#fff}.dropdown-menu > li > a{display:block;padding:3px 20px;clear:both;font-weight:400;line-height:20px;color:#333;white-space:nowrap}.dropdown-menu > li > a:hover,.dropdown-menu > li > a:focus,.dropdown-submenu:hover > a,.dropdown-submenu:focus > a{text-decoration:none;color:#fff;background-color:#1b8032;background-image:-moz-linear-gradient(top,#1d8835,#19732d);background-image:-webkit-gradient(linear,0 0,0 100%,from(#1d8835),to(#19732d));background-image:-webkit-linear-gradient(top,#1d8835,#19732d);background-image:-o-linear-gradient(top,#1d8835,#19732d);background-image:linear-gradient(to bottom,#1d8835,#19732d);background-repeat:repeat-x;filter:progid:DXImageTransform.Microsoft.gradient(startColorstr='#ff1d8835',endColorstr='#ff19732d',GradientType=0)}.dropdown-menu > .active > a,.dropdown-menu > .active > a:hover,.dropdown-menu > .active > a:focus{color:#fff;text-decoration:none;outline:0;background-color:#1b8032;background-image:-moz-linear-gradient(top,#1d8835,#19732d);background-image:-webkit-gradient(linear,0 0,0 100%,from(#1d8835),to(#19732d));background-image:-webkit-linear-gradient(top,#1d8835,#19732d);background-image:-o-linear-gradient(top,#1d8835,#19732d);background-image:linear-gradient(to bottom,#1d8835,#19732d);background-repeat:repeat-x;filter:progid:DXImageTransform.Microsoft.gradient(startColorstr='#ff1d8835',endColorstr='#ff19732d',GradientType=0)}.dropdown-menu > .disabled > a,.dropdown-menu > .disabled > a:hover,.dropdown-menu > .disabled > a:focus{color:#999}.dropdown-menu > .disabled > a:hover,.dropdown-menu > .disabled > a:focus{text-decoration:none;background-color:transparent;background-image:none;filter:progid:DXImageTransform.Microsoft.gradient(enabled = false);cursor:default}.open{*z-index:1000}.open > .dropdown-menu{display:block}.dropdown-backdrop{position:fixed;left:0;right:0;bottom:0;top:0;z-index:990}.pull-right > .dropdown-menu{right:0;left:auto}.dropup .caret,.navbar-fixed-bottom .dropdown .caret{border-top:0;border-bottom:4px solid#000;content:""}.dropup .dropdown-menu,.navbar-fixed-bottom .dropdown .dropdown-menu{top:auto;bottom:100%;margin-bottom:1px}.dropdown-submenu{position:relative}.dropdown-submenu > .dropdown-menu{top:0;left:100%;margin-top:-6px;margin-left:-1px;-webkit-border-radius:0 6px 6px 6px;-moz-border-radius:0 6px 6px 6px;border-radius:0 6px 6px 6px}.dropdown-submenu:hover > .dropdown-menu{display:block}.dropup .dropdown-submenu > .dropdown-menu{top:auto;bottom:0;margin-top:0;margin-bottom:-2px;-webkit-border-radius:5px 5px 5px 0;-moz-border-radius:5px 5px 5px 0;border-radius:5px 5px 5px 0}.dropdown-submenu > a:after{display:block;content:" ";float:right;width:0;height:0;border-color:transparent;border-style:solid;border-width:5px 0 5px 5px;border-left-color:#ccc;margin-top:5px;margin-right:-10px}.dropdown-submenu:hover > a:after{border-left-color:#fff}.dropdown-submenu.pull-left{float:none}.dropdown-submenu.pull-left > .dropdown-menu{left:-100%;margin-left:10px;-webkit-border-radius:6px 0 6px 6px;-moz-border-radius:6px 0 6px 6px;border-radius:6px 0 6px 6px}.dropdown .dropdown-menu .nav-header{padding-left:20px;padding-right:20px}.typeahead{z-index:1051;margin-top:2px;-webkit-border-radius:4px;-moz-border-radius:4px;border-radius:4px}.well{min-height:20px;padding:19px;margin-bottom:20px;background-color:#f5f5f5;border:1px solid #e3e3e3;-webkit-border-radius:4px;-moz-border-radius:4px;border-radius:4px;-webkit-box-shadow:inset 0 1px 1px rgba(0,0,0,0.05);-moz-box-shadow:inset 0 1px 1px rgba(0,0,0,0.05);box-shadow:inset 0 1px 1px rgba(0,0,0,0.05)}.well blockquote{border-color:#ddd;border-color:rgba(0,0,0,0.15)}.well-large{padding:24px;-webkit-border-radius:6px;-moz-border-radius:6px;border-radius:6px}.well-small{padding:9px;-webkit-border-radius:3px;-moz-border-radius:3px;border-radius:3px}.fade{opacity:0;-webkit-transition:opacity .15s linear;-moz-transition:opacity .15s linear;-o-transition:opacity .15s linear;transition:opacity .15s linear}.fade.in{opacity:1}.collapse{position:relative;height:0;overflow:hidden;-webkit-transition:height .35s ease;-moz-transition:height .35s ease;-o-transition:height .35s ease;transition:height .35s ease}.collapse.in{height:auto}.close{float:right;font-size:20px;font-weight:700;line-height:20px;color:#000;text-shadow:0 1px 0#fff;opacity:.2;filter:alpha(opacity=20)}.close:hover,.close:focus{color:#000;text-decoration:none;cursor:pointer;opacity:.4;filter:alpha(opacity=40)}button.close{padding:0;cursor:pointer;background:transparent;border:0;-webkit-appearance:none}.btn{display:inline-block;*display:inline;*zoom:1;padding:4px 12px;margin-bottom:0;font-size:14px;line-height:20px;text-align:center;vertical-align:middle;cursor:pointer;color:#333;text-shadow:0 1px 1px rgba(255,255,255,0.75);background-color:#f5f5f5;background-image:-moz-linear-gradient(top,#fff,#e6e6e6);background-image:-webkit-gradient(linear,0 0,0 100%,from(#fff),to(#e6e6e6));background-image:-webkit-linear-gradient(top,#fff,#e6e6e6);background-image:-o-linear-gradient(top,#fff,#e6e6e6);background-image:linear-gradient(to bottom,#fff,#e6e6e6);background-repeat:repeat-x;filter:progid:DXImageTransform.Microsoft.gradient(startColorstr='#ffffffff',endColorstr='#ffe6e6e6',GradientType=0);border-color:#e6e6e6 #e6e6e6 #bfbfbf;border-color:rgba(0,0,0,0.1) rgba(0,0,0,0.1) rgba(0,0,0,0.25);*background-color:#e6e6e6;filter:progid:DXImageTransform.Microsoft.gradient(enabled = false);border:1px solid#ccc;*border:0;border-bottom-color:#b3b3b3;-webkit-border-radius:4px;-moz-border-radius:4px;border-radius:4px;*margin-left:.3em;-webkit-box-shadow:inset 0 1px 0 rgba(255,255,255,.2),0 1px 2px rgba(0,0,0,.05);-moz-box-shadow:inset 0 1px 0 rgba(255,255,255,.2),0 1px 2px rgba(0,0,0,.05);box-shadow:inset 0 1px 0 rgba(255,255,255,.2),0 1px 2px rgba(0,0,0,.05)}.btn:hover,.btn:focus,.btn:active,.btn.active,.btn.disabled,.btn[disabled]{color:#333;background-color:#e6e6e6;*background-color:#d9d9d9}.btn:active,.btn.active{background-color:#ccc \9}.btn:first-child{*margin-left:0}.btn:hover,.btn:focus{color:#333;text-decoration:none;background-position:0 -15px;-webkit-transition:background-position .1s linear;-moz-transition:background-position .1s linear;-o-transition:background-position .1s linear;transition:background-position .1s linear}.btn:focus{outline:thin dotted #333;outline:5px auto -webkit-focus-ring-color;outline-offset:-2px}.btn.active,.btn:active{background-image:none;outline:0;-webkit-box-shadow:inset 0 2px 4px rgba(0,0,0,.15),0 1px 2px rgba(0,0,0,.05);-moz-box-shadow:inset 0 2px 4px rgba(0,0,0,.15),0 1px 2px rgba(0,0,0,.05);box-shadow:inset 0 2px 4px rgba(0,0,0,.15),0 1px 2px rgba(0,0,0,.05)}.btn.disabled,.btn[disabled]{cursor:default;background-image:none;opacity:.65;filter:alpha(opacity=65);-webkit-box-shadow:none;-moz-box-shadow:none;box-shadow:none}.btn-large{padding:11px 19px;font-size:17.5px;-webkit-border-radius:6px;-moz-border-radius:6px;border-radius:6px}.btn-large [class^="icon-"],.btn-large [class*=" icon-"]{margin-top:4px}.btn-small{padding:2px 10px;font-size:11.9px;-webkit-border-radius:3px;-moz-border-radius:3px;border-radius:3px}.btn-small [class^="icon-"],.btn-small [class*=" icon-"]{margin-top:0}.btn-mini [class^="icon-"],.btn-mini [class*=" icon-"]{margin-top:-1px}.btn-mini{padding:0 6px;font-size:10.5px;-webkit-border-radius:3px;-moz-border-radius:3px;border-radius:3px}.btn-block{display:block;width:100%;padding-left:0;padding-right:0;-webkit-box-sizing:border-box;-moz-box-sizing:border-box;box-sizing:border-box}.btn-block + .btn-block{margin-top:5px}input[type="submit"].btn-block,input[type="reset"].btn-block,input[type="button"].btn-block{width:100%}.btn-primary.active,.btn-warning.active,.btn-danger.active,.btn-success.active,.btn-info.active,.btn-inverse.active{color:rgba(255,255,255,0.75)}.btn-primary{color:#fff;text-shadow:0 -1px 0 rgba(0,0,0,0.25);background-color:#1d8843;background-image:-moz-linear-gradient(top,#1d8835,#1d8859);background-image:-webkit-gradient(linear,0 0,0 100%,from(#1d8835),to(#1d8859));background-image:-webkit-linear-gradient(top,#1d8835,#1d8859);background-image:-o-linear-gradient(top,#1d8835,#1d8859);background-image:linear-gradient(to bottom,#1d8835,#1d8859);background-repeat:repeat-x;filter:progid:DXImageTransform.Microsoft.gradient(startColorstr='#ff1d8835',endColorstr='#ff1d8859',GradientType=0);border-color:#1d8859 #1d8859 #104930;border-color:rgba(0,0,0,0.1) rgba(0,0,0,0.1) rgba(0,0,0,0.25);*background-color:#1d8859;filter:progid:DXImageTransform.Microsoft.gradient(enabled = false)}.btn-primary:hover,.btn-primary:focus,.btn-primary:active,.btn-primary.active,.btn-primary.disabled,.btn-primary[disabled]{color:#fff;background-color:#1d8859;*background-color:#19734b}.btn-primary:active,.btn-primary.active{background-color:#145e3d \9}.btn-warning{color:#fff;text-shadow:0 -1px 0 rgba(0,0,0,0.25);background-color:#faa732;background-image:-moz-linear-gradient(top,#fbb450,#f89406);background-image:-webkit-gradient(linear,0 0,0 100%,from(#fbb450),to(#f89406));background-image:-webkit-linear-gradient(top,#fbb450,#f89406);background-image:-o-linear-gradient(top,#fbb450,#f89406);background-image:linear-gradient(to bottom,#fbb450,#f89406);background-repeat:repeat-x;filter:progid:DXImageTransform.Microsoft.gradient(startColorstr='#fffbb450',endColorstr='#fff89406',GradientType=0);border-color:#f89406 #f89406 #ad6704;border-color:rgba(0,0,0,0.1) rgba(0,0,0,0.1) rgba(0,0,0,0.25);*background-color:#f89406;filter:progid:DXImageTransform.Microsoft.gradient(enabled = false)}.btn-warning:hover,.btn-warning:focus,.btn-warning:active,.btn-warning.active,.btn-warning.disabled,.btn-warning[disabled]{color:#fff;background-color:#f89406;*background-color:#df8505}.btn-warning:active,.btn-warning.active{background-color:#c67605 \9}.btn-danger{color:#fff;text-shadow:0 -1px 0 rgba(0,0,0,0.25);background-color:#da4f49;background-image:-moz-linear-gradient(top,#ee5f5b,#bd362f);background-image:-webkit-gradient(linear,0 0,0 100%,from(#ee5f5b),to(#bd362f));background-image:-webkit-linear-gradient(top,#ee5f5b,#bd362f);background-image:-o-linear-gradient(top,#ee5f5b,#bd362f);background-image:linear-gradient(to bottom,#ee5f5b,#bd362f);background-repeat:repeat-x;filter:progid:DXImageTransform.Microsoft.gradient(startColorstr='#ffee5f5b',endColorstr='#ffbd362f',GradientType=0);border-color:#bd362f #bd362f #802420;border-color:rgba(0,0,0,0.1) rgba(0,0,0,0.1) rgba(0,0,0,0.25);*background-color:#bd362f;filter:progid:DXImageTransform.Microsoft.gradient(enabled = false)}.btn-danger:hover,.btn-danger:focus,.btn-danger:active,.btn-danger.active,.btn-danger.disabled,.btn-danger[disabled]{color:#fff;background-color:#bd362f;*background-color:#a9302a}.btn-danger:active,.btn-danger.active{background-color:#942a25 \9}.btn-success{color:#fff;text-shadow:0 -1px 0 rgba(0,0,0,0.25);background-color:#5bb75b;background-image:-moz-linear-gradient(top,#62c462,#51a351);background-image:-webkit-gradient(linear,0 0,0 100%,from(#62c462),to(#51a351));background-image:-webkit-linear-gradient(top,#62c462,#51a351);background-image:-o-linear-gradient(top,#62c462,#51a351);background-image:linear-gradient(to bottom,#62c462,#51a351);background-repeat:repeat-x;filter:progid:DXImageTransform.Microsoft.gradient(startColorstr='#ff62c462',endColorstr='#ff51a351',GradientType=0);border-color:#51a351 #51a351 #387038;border-color:rgba(0,0,0,0.1) rgba(0,0,0,0.1) rgba(0,0,0,0.25);*background-color:#51a351;filter:progid:DXImageTransform.Microsoft.gradient(enabled = false)}.btn-success:hover,.btn-success:focus,.btn-success:active,.btn-success.active,.btn-success.disabled,.btn-success[disabled]{color:#fff;background-color:#51a351;*background-color:#499249}.btn-success:active,.btn-success.active{background-color:#408140 \9}.btn-info{color:#fff;text-shadow:0 -1px 0 rgba(0,0,0,0.25);background-color:#49afcd;background-image:-moz-linear-gradient(top,#5bc0de,#2f96b4);background-image:-webkit-gradient(linear,0 0,0 100%,from(#5bc0de),to(#2f96b4));background-image:-webkit-linear-gradient(top,#5bc0de,#2f96b4);background-image:-o-linear-gradient(top,#5bc0de,#2f96b4);background-image:linear-gradient(to bottom,#5bc0de,#2f96b4);background-repeat:repeat-x;filter:progid:DXImageTransform.Microsoft.gradient(startColorstr='#ff5bc0de',endColorstr='#ff2f96b4',GradientType=0);border-color:#2f96b4 #2f96b4 #1f6377;border-color:rgba(0,0,0,0.1) rgba(0,0,0,0.1) rgba(0,0,0,0.25);*background-color:#2f96b4;filter:progid:DXImageTransform.Microsoft.gradient(enabled = false)}.btn-info:hover,.btn-info:focus,.btn-info:active,.btn-info.active,.btn-info.disabled,.btn-info[disabled]{color:#fff;background-color:#2f96b4;*background-color:#2a85a0}.btn-info:active,.btn-info.active{background-color:#24748c \9}.btn-inverse{color:#fff;text-shadow:0 -1px 0 rgba(0,0,0,0.25);background-color:#363636;background-image:-moz-linear-gradient(top,#444,#222);background-image:-webkit-gradient(linear,0 0,0 100%,from(#444),to(#222));background-image:-webkit-linear-gradient(top,#444,#222);background-image:-o-linear-gradient(top,#444,#222);background-image:linear-gradient(to bottom,#444,#222);background-repeat:repeat-x;filter:progid:DXImageTransform.Microsoft.gradient(startColorstr='#ff444444',endColorstr='#ff222222',GradientType=0);border-color:#222 #222222#000;border-color:rgba(0,0,0,0.1) rgba(0,0,0,0.1) rgba(0,0,0,0.25);*background-color:#222;filter:progid:DXImageTransform.Microsoft.gradient(enabled = false)}.btn-inverse:hover,.btn-inverse:focus,.btn-inverse:active,.btn-inverse.active,.btn-inverse.disabled,.btn-inverse[disabled]{color:#fff;background-color:#222;*background-color:#151515}.btn-inverse:active,.btn-inverse.active{background-color:#080808 \9}button.btn,input[type="submit"].btn{*padding-top:3px;*padding-bottom:3px}button.btn::-moz-focus-inner,input[type="submit"].btn::-moz-focus-inner{padding:0;border:0}button.btn.btn-large,input[type="submit"].btn.btn-large{*padding-top:7px;*padding-bottom:7px}button.btn.btn-small,input[type="submit"].btn.btn-small{*padding-top:3px;*padding-bottom:3px}button.btn.btn-mini,input[type="submit"].btn.btn-mini{*padding-top:1px;*padding-bottom:1px}.btn-link,.btn-link:active,.btn-link[disabled]{background-color:transparent;background-image:none;-webkit-box-shadow:none;-moz-box-shadow:none;box-shadow:none}.btn-link{border-color:transparent;cursor:pointer;color:#1d8835;-webkit-border-radius:0;-moz-border-radius:0;border-radius:0}.btn-link:hover,.btn-link:focus{color:#10491c;text-decoration:underline;background-color:transparent}.btn-link[disabled]:hover,.btn-link[disabled]:focus{color:#333;text-decoration:none}.btn-group{position:relative;display:inline-block;*display:inline;*zoom:1;font-size:0;vertical-align:middle;white-space:nowrap;*margin-left:.3em}.btn-group:first-child{*margin-left:0}.btn-group + .btn-group{margin-left:5px}.btn-toolbar{font-size:0;margin-top:10px;margin-bottom:10px}.btn-toolbar > .btn + .btn,.btn-toolbar > .btn-group + .btn,.btn-toolbar > .btn + .btn-group{margin-left:5px}.btn-group > .btn{position:relative;-webkit-border-radius:0;-moz-border-radius:0;border-radius:0}.btn-group > .btn + .btn{margin-left:-1px}.btn-group > .btn,.btn-group > .dropdown-menu,.btn-group > .popover{font-size:14px}.btn-group > .btn-mini{font-size:10.5px}.btn-group > .btn-small{font-size:11.9px}.btn-group > .btn-large{font-size:17.5px}.btn-group > .btn:first-child{margin-left:0;-webkit-border-top-left-radius:4px;-moz-border-radius-topleft:4px;border-top-left-radius:4px;-webkit-border-bottom-left-radius:4px;-moz-border-radius-bottomleft:4px;border-bottom-left-radius:4px}.btn-group > .btn:last-child,.btn-group > .dropdown-toggle{-webkit-border-top-right-radius:4px;-moz-border-radius-topright:4px;border-top-right-radius:4px;-webkit-border-bottom-right-radius:4px;-moz-border-radius-bottomright:4px;border-bottom-right-radius:4px}.btn-group > .btn.large:first-child{margin-left:0;-webkit-border-top-left-radius:6px;-moz-border-radius-topleft:6px;border-top-left-radius:6px;-webkit-border-bottom-left-radius:6px;-moz-border-radius-bottomleft:6px;border-bottom-left-radius:6px}.btn-group > .btn.large:last-child,.btn-group > .large.dropdown-toggle{-webkit-border-top-right-radius:6px;-moz-border-radius-topright:6px;border-top-right-radius:6px;-webkit-border-bottom-right-radius:6px;-moz-border-radius-bottomright:6px;border-bottom-right-radius:6px}.btn-group > .btn:hover,.btn-group > .btn:focus,.btn-group > .btn:active,.btn-group > .btn.active{z-index:2}.btn-group .dropdown-toggle:active,.btn-group.open .dropdown-toggle{outline:0}.btn-group > .btn + .dropdown-toggle{padding-left:8px;padding-right:8px;-webkit-box-shadow:inset 1px 0 0 rgba(255,255,255,.125),inset 0 1px 0 rgba(255,255,255,.2),0 1px 2px rgba(0,0,0,.05);-moz-box-shadow:inset 1px 0 0 rgba(255,255,255,.125),inset 0 1px 0 rgba(255,255,255,.2),0 1px 2px rgba(0,0,0,.05);box-shadow:inset 1px 0 0 rgba(255,255,255,.125),inset 0 1px 0 rgba(255,255,255,.2),0 1px 2px rgba(0,0,0,.05);*padding-top:5px;*padding-bottom:5px}.btn-group > .btn-mini + .dropdown-toggle{padding-left:5px;padding-right:5px;*padding-top:2px;*padding-bottom:2px}.btn-group > .btn-small + .dropdown-toggle{*padding-top:5px;*padding-bottom:4px}.btn-group > .btn-large + .dropdown-toggle{padding-left:12px;padding-right:12px;*padding-top:7px;*padding-bottom:7px}.btn-group.open .dropdown-toggle{background-image:none;-webkit-box-shadow:inset 0 2px 4px rgba(0,0,0,.15),0 1px 2px rgba(0,0,0,.05);-moz-box-shadow:inset 0 2px 4px rgba(0,0,0,.15),0 1px 2px rgba(0,0,0,.05);box-shadow:inset 0 2px 4px rgba(0,0,0,.15),0 1px 2px rgba(0,0,0,.05)}.btn-group.open .btn.dropdown-toggle{background-color:#e6e6e6}.btn-group.open .btn-primary.dropdown-toggle{background-color:#1d8859}.btn-group.open .btn-warning.dropdown-toggle{background-color:#f89406}.btn-group.open .btn-danger.dropdown-toggle{background-color:#bd362f}.btn-group.open .btn-success.dropdown-toggle{background-color:#51a351}.btn-group.open .btn-info.dropdown-toggle{background-color:#2f96b4}.btn-group.open .btn-inverse.dropdown-toggle{background-color:#222}.btn .caret{margin-top:8px;margin-left:0}.btn-large .caret{margin-top:6px}.btn-large .caret{border-left-width:5px;border-right-width:5px;border-top-width:5px}.btn-mini .caret,.btn-small .caret{margin-top:8px}.dropup .btn-large .caret{border-bottom-width:5px}.btn-primary .caret,.btn-warning .caret,.btn-danger .caret,.btn-info .caret,.btn-success .caret,.btn-inverse .caret{border-top-color:#fff;border-bottom-color:#fff}.btn-group-vertical{display:inline-block;*display:inline;*zoom:1}.btn-group-vertical > .btn{display:block;float:none;max-width:100%;-webkit-border-radius:0;-moz-border-radius:0;border-radius:0}.btn-group-vertical > .btn + .btn{margin-left:0;margin-top:-1px}.btn-group-vertical > .btn:first-child{-webkit-border-radius:4px 4px 0 0;-moz-border-radius:4px 4px 0 0;border-radius:4px 4px 0 0}.btn-group-vertical > .btn:last-child{-webkit-border-radius:0 0 4px 4px;-moz-border-radius:0 0 4px 4px;border-radius:0 0 4px 4px}.btn-group-vertical > .btn-large:first-child{-webkit-border-radius:6px 6px 0 0;-moz-border-radius:6px 6px 0 0;border-radius:6px 6px 0 0}.btn-group-vertical > .btn-large:last-child{-webkit-border-radius:0 0 6px 6px;-moz-border-radius:0 0 6px 6px;border-radius:0 0 6px 6px}.alert{padding:8px 35px 8px 14px;margin-bottom:20px;text-shadow:0 1px 0 rgba(255,255,255,0.5);background-color:#fcf8e3;border:1px solid #fbeed5;-webkit-border-radius:4px;-moz-border-radius:4px;border-radius:4px}.alert,.alert h4{color:#c09853}.alert h4{margin:0}.alert .close{position:relative;top:-2px;right:-21px;line-height:20px}.alert-success{background-color:#dff0d8;border-color:#d6e9c6;color:#468847}.alert-success h4{color:#468847}.alert-danger,.alert-error{background-color:#f2dede;border-color:#eed3d7;color:#b94a48}.alert-danger h4,.alert-error h4{color:#b94a48}.alert-info{background-color:#d9edf7;border-color:#bce8f1;color:#3a87ad}.alert-info h4{color:#3a87ad}.alert-block{padding-top:14px;padding-bottom:14px}.alert-block > p,.alert-block > ul{margin-bottom:0}.alert-block p + p{margin-top:5px}.nav{margin-left:0;margin-bottom:20px;list-style:none}.nav > li > a{display:block}.nav > li > a:hover,.nav > li > a:focus{text-decoration:none;background-color:#eee}.nav > li > a > img{max-width:none}.nav > .pull-right{float:right}.nav-header{display:block;padding:3px 15px;font-size:11px;font-weight:700;line-height:20px;color:#999;text-shadow:0 1px 0 rgba(255,255,255,0.5);text-transform:uppercase}.nav li + .nav-header{margin-top:9px}.nav-list{padding-left:15px;padding-right:15px;margin-bottom:0}.nav-list > li > a,.nav-list .nav-header{margin-left:-15px;margin-right:-15px;text-shadow:0 1px 0 rgba(255,255,255,0.5)}.nav-list > li > a{padding:3px 15px}.nav-list > .active > a,.nav-list > .active > a:hover,.nav-list > .active > a:focus{color:#fff;text-shadow:0 -1px 0 rgba(0,0,0,0.2);background-color:#1d8835}.nav-list [class^="icon-"],.nav-list [class*=" icon-"]{margin-right:2px}.nav-list .divider{*width:100%;height:1px;margin:9px 1px;*margin:-5px 0 5px;overflow:hidden;background-color:#e5e5e5;border-bottom:1px solid#fff}.nav-tabs,.nav-pills{*zoom:1}.nav-tabs:before,.nav-pills:before,.nav-tabs:after,.nav-pills:after{display:table;content:"";line-height:0}.nav-tabs:after,.nav-pills:after{clear:both}.nav-tabs > li,.nav-pills > li{float:left}.nav-tabs > li > a,.nav-pills > li > a{padding-right:12px;padding-left:12px;margin-right:2px;line-height:14px}.nav-tabs{border-bottom:1px solid #ddd}.nav-tabs > li{margin-bottom:-1px}.nav-tabs > li > a{padding-top:8px;padding-bottom:8px;line-height:20px;border:1px solid transparent;-webkit-border-radius:4px 4px 0 0;-moz-border-radius:4px 4px 0 0;border-radius:4px 4px 0 0}.nav-tabs > li > a:hover,.nav-tabs > li > a:focus{border-color:#eee #eeeeee#ddd}.nav-tabs > .active > a,.nav-tabs > .active > a:hover,.nav-tabs > .active > a:focus{color:#555;background-color:#fff;border:1px solid #ddd;border-bottom-color:transparent;cursor:default}.nav-pills > li > a{padding-top:8px;padding-bottom:8px;margin-top:2px;margin-bottom:2px;-webkit-border-radius:5px;-moz-border-radius:5px;border-radius:5px}.nav-pills > .active > a,.nav-pills > .active > a:hover,.nav-pills > .active > a:focus{color:#fff;background-color:#1d8835}.nav-stacked > li{float:none}.nav-stacked > li > a{margin-right:0}.nav-tabs.nav-stacked{border-bottom:0}.nav-tabs.nav-stacked > li > a{border:1px solid #ddd;-webkit-border-radius:0;-moz-border-radius:0;border-radius:0}.nav-tabs.nav-stacked > li:first-child > a{-webkit-border-top-right-radius:4px;-moz-border-radius-topright:4px;border-top-right-radius:4px;-webkit-border-top-left-radius:4px;-moz-border-radius-topleft:4px;border-top-left-radius:4px}.nav-tabs.nav-stacked > li:last-child > a{-webkit-border-bottom-right-radius:4px;-moz-border-radius-bottomright:4px;border-bottom-right-radius:4px;-webkit-border-bottom-left-radius:4px;-moz-border-radius-bottomleft:4px;border-bottom-left-radius:4px}.nav-tabs.nav-stacked > li > a:hover,.nav-tabs.nav-stacked > li > a:focus{border-color:#ddd;z-index:2}.nav-pills.nav-stacked > li > a{margin-bottom:3px}.nav-pills.nav-stacked > li:last-child > a{margin-bottom:1px}.nav-tabs .dropdown-menu{-webkit-border-radius:0 0 6px 6px;-moz-border-radius:0 0 6px 6px;border-radius:0 0 6px 6px}.nav-pills .dropdown-menu{-webkit-border-radius:6px;-moz-border-radius:6px;border-radius:6px}.nav .dropdown-toggle .caret{border-top-color:#1d8835;border-bottom-color:#1d8835;margin-top:6px}.nav .dropdown-toggle:hover .caret,.nav .dropdown-toggle:focus .caret{border-top-color:#10491c;border-bottom-color:#10491c}.nav-tabs .dropdown-toggle .caret{margin-top:8px}.nav .active .dropdown-toggle .caret{border-top-color:#fff;border-bottom-color:#fff}.nav-tabs .active .dropdown-toggle .caret{border-top-color:#555;border-bottom-color:#555}.nav > .dropdown.active > a:hover,.nav > .dropdown.active > a:focus{cursor:pointer}.nav-tabs .open .dropdown-toggle,.nav-pills .open .dropdown-toggle,.nav > li.dropdown.open.active > a:hover,.nav > li.dropdown.open.active > a:focus{color:#fff;background-color:#999;border-color:#999}.nav li.dropdown.open .caret,.nav li.dropdown.open.active .caret,.nav li.dropdown.open a:hover .caret,.nav li.dropdown.open a:focus .caret{border-top-color:#fff;border-bottom-color:#fff;opacity:1;filter:alpha(opacity=100)}.tabs-stacked .open > a:hover,.tabs-stacked .open > a:focus{border-color:#999}.tabbable{*zoom:1}.tabbable:before,.tabbable:after{display:table;content:"";line-height:0}.tabbable:after{clear:both}.tab-content{overflow:auto}.tabs-below > .nav-tabs,.tabs-right > .nav-tabs,.tabs-left > .nav-tabs{border-bottom:0}.tab-content > .tab-pane,.pill-content > .pill-pane{display:none}.tab-content > .active,.pill-content > .active{display:block}.tabs-below > .nav-tabs{border-top:1px solid #ddd}.tabs-below > .nav-tabs > li{margin-top:-1px;margin-bottom:0}.tabs-below > .nav-tabs > li > a{-webkit-border-radius:0 0 4px 4px;-moz-border-radius:0 0 4px 4px;border-radius:0 0 4px 4px}.tabs-below > .nav-tabs > li > a:hover,.tabs-below > .nav-tabs > li > a:focus{border-bottom-color:transparent;border-top-color:#ddd}.tabs-below > .nav-tabs > .active > a,.tabs-below > .nav-tabs > .active > a:hover,.tabs-below > .nav-tabs > .active > a:focus{border-color:transparent #ddd #ddd #ddd}.tabs-left > .nav-tabs > li,.tabs-right > .nav-tabs > li{float:none}.tabs-left > .nav-tabs > li > a,.tabs-right > .nav-tabs > li > a{min-width:74px;margin-right:0;margin-bottom:3px}.tabs-left > .nav-tabs{float:left;margin-right:19px;border-right:1px solid #ddd}.tabs-left > .nav-tabs > li > a{margin-right:-1px;-webkit-border-radius:4px 0 0 4px;-moz-border-radius:4px 0 0 4px;border-radius:4px 0 0 4px}.tabs-left > .nav-tabs > li > a:hover,.tabs-left > .nav-tabs > li > a:focus{border-color:#eee #dddddd#eee #eeeeee}.tabs-left > .nav-tabs .active > a,.tabs-left > .nav-tabs .active > a:hover,.tabs-left > .nav-tabs .active > a:focus{border-color:#ddd transparent #ddd #ddd;*border-right-color:#fff}.tabs-right > .nav-tabs{float:right;margin-left:19px;border-left:1px solid #ddd}.tabs-right > .nav-tabs > li > a{margin-left:-1px;-webkit-border-radius:0 4px 4px 0;-moz-border-radius:0 4px 4px 0;border-radius:0 4px 4px 0}.tabs-right > .nav-tabs > li > a:hover,.tabs-right > .nav-tabs > li > a:focus{border-color:#eee #eeeeee#eee #dddddd}.tabs-right > .nav-tabs .active > a,.tabs-right > .nav-tabs .active > a:hover,.tabs-right > .nav-tabs .active > a:focus{border-color:#ddd #ddd #ddd transparent;*border-left-color:#fff}.nav > .disabled > a{color:#999}.nav > .disabled > a:hover,.nav > .disabled > a:focus{text-decoration:none;background-color:transparent;cursor:default}.navbar{overflow:visible;margin-bottom:20px;*position:relative;*z-index:2}.navbar-inner{min-height:60px;padding-left:20px;padding-right:20px;background-color:#fafafa;background-image:-moz-linear-gradient(top,#fff,#f2f2f2);background-image:-webkit-gradient(linear,0 0,0 100%,from(#fff),to(#f2f2f2));background-image:-webkit-linear-gradient(top,#fff,#f2f2f2);background-image:-o-linear-gradient(top,#fff,#f2f2f2);background-image:linear-gradient(to bottom,#fff,#f2f2f2);background-repeat:repeat-x;filter:progid:DXImageTransform.Microsoft.gradient(startColorstr='#ffffffff',endColorstr='#fff2f2f2',GradientType=0);border:1px solid #d4d4d4;-webkit-border-radius:4px;-moz-border-radius:4px;border-radius:4px;-webkit-box-shadow:0 1px 4px rgba(0,0,0,0.065);-moz-box-shadow:0 1px 4px rgba(0,0,0,0.065);box-shadow:0 1px 4px rgba(0,0,0,0.065);*zoom:1}.navbar-inner:before,.navbar-inner:after{display:table;content:"";line-height:0}.navbar-inner:after{clear:both}.navbar .container{width:auto}.nav-collapse.collapse{height:auto;overflow:visible}.navbar .brand{float:left;display:block;padding:20px 20px 20px;margin-left:-20px;font-size:20px;font-weight:200;color:#fff;text-shadow:0 1px 0#fff}.navbar .brand:hover,.navbar .brand:focus{text-decoration:none}.navbar-text{margin-bottom:0;line-height:60px;color:#777}.navbar-link{color:#777}.navbar-link:hover,.navbar-link:focus{color:#333}.navbar .divider-vertical{height:60px;margin:0 9px;border-left:1px solid #f2f2f2;border-right:1px solid#fff}.navbar .btn,.navbar .btn-group{margin-top:15px}.navbar .btn-group .btn,.navbar .input-prepend .btn,.navbar .input-append .btn,.navbar .input-prepend .btn-group,.navbar .input-append .btn-group{margin-top:0}.navbar-form{margin-bottom:0;*zoom:1}.navbar-form:before,.navbar-form:after{display:table;content:"";line-height:0}.navbar-form:after{clear:both}.navbar-form input,.navbar-form select,.navbar-form .radio,.navbar-form .checkbox{margin-top:15px}.navbar-form input,.navbar-form select,.navbar-form .btn{display:inline-block;margin-bottom:0}.navbar-form input[type="image"],.navbar-form input[type="checkbox"],.navbar-form input[type="radio"]{margin-top:3px}.navbar-form .input-append,.navbar-form .input-prepend{margin-top:5px;white-space:nowrap}.navbar-form .input-append input,.navbar-form .input-prepend input{margin-top:0}.navbar-search{position:relative;float:left;margin-top:15px;margin-bottom:0}.navbar-search .search-query{margin-bottom:0;padding:4px 14px;font-family:"Helvetica Neue",Helvetica,Arial,sans-serif;font-size:13px;font-weight:400;line-height:1;-webkit-border-radius:15px;-moz-border-radius:15px;border-radius:15px}.navbar-static-top{position:static;margin-bottom:0}.navbar-static-top .navbar-inner{-webkit-border-radius:0;-moz-border-radius:0;border-radius:0}.navbar-fixed-top,.navbar-fixed-bottom{position:fixed;right:0;left:0;z-index:1010;margin-bottom:0}.navbar-fixed-top .navbar-inner,.navbar-static-top .navbar-inner{border-width:0 0 1px}.navbar-fixed-bottom .navbar-inner{border-width:1px 0 0}.navbar-fixed-top .navbar-inner,.navbar-fixed-bottom .navbar-inner{padding-left:0;padding-right:0;-webkit-border-radius:0;-moz-border-radius:0;border-radius:0}.navbar-static-top .container,.navbar-fixed-top .container,.navbar-fixed-bottom .container{width:940px}.navbar-fixed-top{top:0}.navbar-fixed-top .navbar-inner,.navbar-static-top .navbar-inner{-webkit-box-shadow:0 1px 10px rgba(0,0,0,.1);-moz-box-shadow:0 1px 10px rgba(0,0,0,.1);box-shadow:0 1px 10px rgba(0,0,0,.1)}.navbar-fixed-bottom{bottom:0}.navbar-fixed-bottom .navbar-inner{-webkit-box-shadow:0 -1px 10px rgba(0,0,0,.1);-moz-box-shadow:0 -1px 10px rgba(0,0,0,.1);box-shadow:0 -1px 10px rgba(0,0,0,.1)}.navbar .nav{position:relative;left:0;display:block;float:left;margin:0 10px 0 0}.navbar .nav.pull-right{float:right;margin-right:0}.navbar .nav > li{float:left}.navbar .nav > li > a{float:none;padding:20px 15px 20px;color:#777;text-decoration:none;text-shadow:0 1px 0#fff}.navbar .nav .dropdown-toggle .caret{margin-top:8px}.navbar .nav > li > a:focus,.navbar .nav > li > a:hover{background-color:transparent;color:#333;text-decoration:none}.navbar .nav > .active > a,.navbar .nav > .active > a:hover,.navbar .nav > .active > a:focus{color:#555;text-decoration:none;background-color:#e5e5e5;-webkit-box-shadow:inset 0 3px 8px rgba(0,0,0,0.125);-moz-box-shadow:inset 0 3px 8px rgba(0,0,0,0.125);box-shadow:inset 0 3px 8px rgba(0,0,0,0.125)}.navbar .btn-navbar{display:none;float:right;padding:7px 10px;margin-left:5px;margin-right:5px;color:#fff;text-shadow:0 -1px 0 rgba(0,0,0,0.25);background-color:#ededed;background-image:-moz-linear-gradient(top,#f2f2f2,#e5e5e5);background-image:-webkit-gradient(linear,0 0,0 100%,from(#f2f2f2),to(#e5e5e5));background-image:-webkit-linear-gradient(top,#f2f2f2,#e5e5e5);background-image:-o-linear-gradient(top,#f2f2f2,#e5e5e5);background-image:linear-gradient(to bottom,#f2f2f2,#e5e5e5);background-repeat:repeat-x;filter:progid:DXImageTransform.Microsoft.gradient(startColorstr='#fff2f2f2',endColorstr='#ffe5e5e5',GradientType=0);border-color:#e5e5e5 #e5e5e5 #bfbfbf;border-color:rgba(0,0,0,0.1) rgba(0,0,0,0.1) rgba(0,0,0,0.25);*background-color:#e5e5e5;filter:progid:DXImageTransform.Microsoft.gradient(enabled = false);-webkit-box-shadow:inset 0 1px 0 rgba(255,255,255,.1),0 1px 0 rgba(255,255,255,.075);-moz-box-shadow:inset 0 1px 0 rgba(255,255,255,.1),0 1px 0 rgba(255,255,255,.075);box-shadow:inset 0 1px 0 rgba(255,255,255,.1),0 1px 0 rgba(255,255,255,.075)}.navbar .btn-navbar:hover,.navbar .btn-navbar:focus,.navbar .btn-navbar:active,.navbar .btn-navbar.active,.navbar .btn-navbar.disabled,.navbar .btn-navbar[disabled]{color:#fff;background-color:#e5e5e5;*background-color:#d9d9d9}.navbar .btn-navbar:active,.navbar .btn-navbar.active{background-color:#ccc \9}.navbar .btn-navbar .icon-bar{display:block;width:18px;height:2px;background-color:#f5f5f5;-webkit-border-radius:1px;-moz-border-radius:1px;border-radius:1px;-webkit-box-shadow:0 1px 0 rgba(0,0,0,0.25);-moz-box-shadow:0 1px 0 rgba(0,0,0,0.25);box-shadow:0 1px 0 rgba(0,0,0,0.25)}.btn-navbar .icon-bar + .icon-bar{margin-top:3px}.navbar .nav > li > .dropdown-menu:before{content:'';display:inline-block;border-left:7px solid transparent;border-right:7px solid transparent;border-bottom:7px solid #ccc;border-bottom-color:rgba(0,0,0,0.2);position:absolute;top:-7px;left:9px}.navbar .nav > li > .dropdown-menu:after{content:'';display:inline-block;border-left:6px solid transparent;border-right:6px solid transparent;border-bottom:6px solid#fff;position:absolute;top:-6px;left:10px}.navbar-fixed-bottom .nav > li > .dropdown-menu:before{border-top:7px solid #ccc;border-top-color:rgba(0,0,0,0.2);border-bottom:0;bottom:-7px;top:auto}.navbar-fixed-bottom .nav > li > .dropdown-menu:after{border-top:6px solid#fff;border-bottom:0;bottom:-6px;top:auto}.navbar .nav li.dropdown > a:hover .caret,.navbar .nav li.dropdown > a:focus .caret{border-top-color:#333;border-bottom-color:#333}.navbar .nav li.dropdown.open > .dropdown-toggle,.navbar .nav li.dropdown.active > .dropdown-toggle,.navbar .nav li.dropdown.open.active > .dropdown-toggle{background-color:#e5e5e5;color:#555}.navbar .nav li.dropdown > .dropdown-toggle .caret{border-top-color:#777;border-bottom-color:#777}.navbar .nav li.dropdown.open > .dropdown-toggle .caret,.navbar .nav li.dropdown.active > .dropdown-toggle .caret,.navbar .nav li.dropdown.open.active > .dropdown-toggle .caret{border-top-color:#555;border-bottom-color:#555}.navbar .pull-right > li > .dropdown-menu,.navbar .nav > li > .dropdown-menu.pull-right{left:auto;right:0}.navbar .pull-right > li > .dropdown-menu:before,.navbar .nav > li > .dropdown-menu.pull-right:before{left:auto;right:12px}.navbar .pull-right > li > .dropdown-menu:after,.navbar .nav > li > .dropdown-menu.pull-right:after{left:auto;right:13px}.navbar .pull-right > li > .dropdown-menu .dropdown-menu,.navbar .nav > li > .dropdown-menu.pull-right .dropdown-menu{left:auto;right:100%;margin-left:0;margin-right:-1px;-webkit-border-radius:6px 0 6px 6px;-moz-border-radius:6px 0 6px 6px;border-radius:6px 0 6px 6px}.navbar-inverse .navbar-inner{background-color:#1b1b1b;background-image:-moz-linear-gradient(top,#222,#111);background-image:-webkit-gradient(linear,0 0,0 100%,from(#222),to(#111));background-image:-webkit-linear-gradient(top,#222,#111);background-image:-o-linear-gradient(top,#222,#111);background-image:linear-gradient(to bottom,#222,#111);background-repeat:repeat-x;filter:progid:DXImageTransform.Microsoft.gradient(startColorstr='#ff222222',endColorstr='#ff111111',GradientType=0);border-color:#252525}.navbar-inverse .brand,.navbar-inverse .nav > li > a{color:#999;text-shadow:0 -1px 0 rgba(0,0,0,0.25)}.navbar-inverse .brand:hover,.navbar-inverse .nav > li > a:hover,.navbar-inverse .brand:focus,.navbar-inverse .nav > li > a:focus{color:#fff}.navbar-inverse .brand{color:#999}.navbar-inverse .navbar-text{color:#999}.navbar-inverse .nav > li > a:focus,.navbar-inverse .nav > li > a:hover{background-color:transparent;color:#fff}.navbar-inverse .nav .active > a,.navbar-inverse .nav .active > a:hover,.navbar-inverse .nav .active > a:focus{color:#fff;background-color:#111}.navbar-inverse .navbar-link{color:#999}.navbar-inverse .navbar-link:hover,.navbar-inverse .navbar-link:focus{color:#fff}.navbar-inverse .divider-vertical{border-left-color:#111;border-right-color:#222}.navbar-inverse .nav li.dropdown.open > .dropdown-toggle,.navbar-inverse .nav li.dropdown.active > .dropdown-toggle,.navbar-inverse .nav li.dropdown.open.active > .dropdown-toggle{background-color:#111;color:#fff}.navbar-inverse .nav li.dropdown > a:hover .caret,.navbar-inverse .nav li.dropdown > a:focus .caret{border-top-color:#fff;border-bottom-color:#fff}.navbar-inverse .nav li.dropdown > .dropdown-toggle .caret{border-top-color:#999;border-bottom-color:#999}.navbar-inverse .nav li.dropdown.open > .dropdown-toggle .caret,.navbar-inverse .nav li.dropdown.active > .dropdown-toggle .caret,.navbar-inverse .nav li.dropdown.open.active > .dropdown-toggle .caret{border-top-color:#fff;border-bottom-color:#fff}.navbar-inverse .navbar-search .search-query{color:#fff;background-color:#515151;border-color:#111;-webkit-box-shadow:inset 0 1px 2px rgba(0,0,0,.1),0 1px 0 rgba(255,255,255,.15);-moz-box-shadow:inset 0 1px 2px rgba(0,0,0,.1),0 1px 0 rgba(255,255,255,.15);box-shadow:inset 0 1px 2px rgba(0,0,0,.1),0 1px 0 rgba(255,255,255,.15);-webkit-transition:none;-moz-transition:none;-o-transition:none;transition:none}.navbar-inverse .navbar-search .search-query:-moz-placeholder{color:#ccc}.navbar-inverse .navbar-search .search-query:-ms-input-placeholder{color:#ccc}.navbar-inverse .navbar-search .search-query::-webkit-input-placeholder{color:#ccc}.navbar-inverse .navbar-search .search-query:focus,.navbar-inverse .navbar-search .search-query.focused{padding:5px 15px;color:#333;text-shadow:0 1px 0#fff;background-color:#fff;border:0;-webkit-box-shadow:0 0 3px rgba(0,0,0,0.15);-moz-box-shadow:0 0 3px rgba(0,0,0,0.15);box-shadow:0 0 3px rgba(0,0,0,0.15);outline:0}.navbar-inverse .btn-navbar{color:#fff;text-shadow:0 -1px 0 rgba(0,0,0,0.25);background-color:#0e0e0e;background-image:-moz-linear-gradient(top,#151515,#040404);background-image:-webkit-gradient(linear,0 0,0 100%,from(#151515),to(#040404));background-image:-webkit-linear-gradient(top,#151515,#040404);background-image:-o-linear-gradient(top,#151515,#040404);background-image:linear-gradient(to bottom,#151515,#040404);background-repeat:repeat-x;filter:progid:DXImageTransform.Microsoft.gradient(startColorstr='#ff151515',endColorstr='#ff040404',GradientType=0);border-color:#040404 #040404#000;border-color:rgba(0,0,0,0.1) rgba(0,0,0,0.1) rgba(0,0,0,0.25);*background-color:#040404;filter:progid:DXImageTransform.Microsoft.gradient(enabled = false)}.navbar-inverse .btn-navbar:hover,.navbar-inverse .btn-navbar:focus,.navbar-inverse .btn-navbar:active,.navbar-inverse .btn-navbar.active,.navbar-inverse .btn-navbar.disabled,.navbar-inverse .btn-navbar[disabled]{color:#fff;background-color:#040404;*background-color:#000}.navbar-inverse .btn-navbar:active,.navbar-inverse .btn-navbar.active{background-color:#000 \9}.breadcrumb{padding:8px 15px;margin:0 0 20px;list-style:none;background-color:#f5f5f5;-webkit-border-radius:4px;-moz-border-radius:4px;border-radius:4px}.breadcrumb > li{display:inline-block;*display:inline;*zoom:1;text-shadow:0 1px 0#fff}.breadcrumb > li > .divider{padding:0 5px;color:#ccc}.breadcrumb > .active{color:#999}.pagination{margin:20px 0}.pagination ul{display:inline-block;*display:inline;*zoom:1;margin-left:0;margin-bottom:0;-webkit-border-radius:4px;-moz-border-radius:4px;border-radius:4px;-webkit-box-shadow:0 1px 2px rgba(0,0,0,0.05);-moz-box-shadow:0 1px 2px rgba(0,0,0,0.05);box-shadow:0 1px 2px rgba(0,0,0,0.05)}.pagination ul > li{display:inline}.pagination ul > li > a,.pagination ul > li > span{float:left;padding:4px 12px;line-height:20px;text-decoration:none;background-color:#fff;border:1px solid#ddd;border-left-width:0}.pagination ul > li > a:hover,.pagination ul > li > a:focus,.pagination ul > .active > a,.pagination ul > .active > span{background-color:#f5f5f5}.pagination ul > .active > a,.pagination ul > .active > span{color:#999;cursor:default}.pagination ul > .disabled > span,.pagination ul > .disabled > a,.pagination ul > .disabled > a:hover,.pagination ul > .disabled > a:focus{color:#999;background-color:transparent;cursor:default}.pagination ul > li:first-child > a,.pagination ul > li:first-child > span{border-left-width:1px;-webkit-border-top-left-radius:4px;-moz-border-radius-topleft:4px;border-top-left-radius:4px;-webkit-border-bottom-left-radius:4px;-moz-border-radius-bottomleft:4px;border-bottom-left-radius:4px}.pagination ul > li:last-child > a,.pagination ul > li:last-child > span{-webkit-border-top-right-radius:4px;-moz-border-radius-topright:4px;border-top-right-radius:4px;-webkit-border-bottom-right-radius:4px;-moz-border-radius-bottomright:4px;border-bottom-right-radius:4px}.pagination-centered{text-align:center}.pagination-right{text-align:right}.pagination-large ul > li > a,.pagination-large ul > li > span{padding:11px 19px;font-size:17.5px}.pagination-large ul > li:first-child > a,.pagination-large ul > li:first-child > span{-webkit-border-top-left-radius:6px;-moz-border-radius-topleft:6px;border-top-left-radius:6px;-webkit-border-bottom-left-radius:6px;-moz-border-radius-bottomleft:6px;border-bottom-left-radius:6px}.pagination-large ul > li:last-child > a,.pagination-large ul > li:last-child > span{-webkit-border-top-right-radius:6px;-moz-border-radius-topright:6px;border-top-right-radius:6px;-webkit-border-bottom-right-radius:6px;-moz-border-radius-bottomright:6px;border-bottom-right-radius:6px}.pagination-mini ul > li:first-child > a,.pagination-small ul > li:first-child > a,.pagination-mini ul > li:first-child > span,.pagination-small ul > li:first-child > span{-webkit-border-top-left-radius:3px;-moz-border-radius-topleft:3px;border-top-left-radius:3px;-webkit-border-bottom-left-radius:3px;-moz-border-radius-bottomleft:3px;border-bottom-left-radius:3px}.pagination-mini ul > li:last-child > a,.pagination-small ul > li:last-child > a,.pagination-mini ul > li:last-child > span,.pagination-small ul > li:last-child > span{-webkit-border-top-right-radius:3px;-moz-border-radius-topright:3px;border-top-right-radius:3px;-webkit-border-bottom-right-radius:3px;-moz-border-radius-bottomright:3px;border-bottom-right-radius:3px}.pagination-small ul > li > a,.pagination-small ul > li > span{padding:2px 10px;font-size:11.9px}.pagination-mini ul > li > a,.pagination-mini ul > li > span{padding:0 6px;font-size:10.5px}.pager{margin:20px 0;list-style:none;text-align:center;*zoom:1}.pager:before,.pager:after{display:table;content:"";line-height:0}.pager:after{clear:both}.pager li{display:inline}.pager li > a,.pager li > span{display:inline-block;padding:5px 14px;background-color:#fff;border:1px solid #ddd;-webkit-border-radius:15px;-moz-border-radius:15px;border-radius:15px}.pager li > a:hover,.pager li > a:focus{text-decoration:none;background-color:#f5f5f5}.pager .next > a,.pager .next > span{float:right}.pager .previous > a,.pager .previous > span{float:left}.pager .disabled > a,.pager .disabled > a:hover,.pager .disabled > a:focus,.pager .disabled > span{color:#999;background-color:#fff;cursor:default}.modal-backdrop{position:fixed;top:0;right:0;bottom:0;left:0;z-index:1040;background-color:#000}.modal-backdrop.fade{opacity:0}.modal-backdrop,.modal-backdrop.fade.in{opacity:.8;filter:alpha(opacity=80)}.modal{position:fixed;top:10%;left:50%;z-index:1050;width:560px;margin-left:-280px;background-color:#fff;border:1px solid #999;border:1px solid rgba(0,0,0,0.3);*border:1px solid #999;-webkit-border-radius:6px;-moz-border-radius:6px;border-radius:6px;-webkit-box-shadow:0 3px 7px rgba(0,0,0,0.3);-moz-box-shadow:0 3px 7px rgba(0,0,0,0.3);box-shadow:0 3px 7px rgba(0,0,0,0.3);-webkit-background-clip:padding-box;-moz-background-clip:padding-box;background-clip:padding-box;outline:none}.modal.fade{-webkit-transition:opacity .3s linear,top .3s ease-out;-moz-transition:opacity .3s linear,top .3s ease-out;-o-transition:opacity .3s linear,top .3s ease-out;transition:opacity .3s linear,top .3s ease-out;top:-25%}.modal.fade.in{top:10%}.modal-header{padding:9px 15px;border-bottom:1px solid #eee}.modal-header .close{margin-top:2px}.modal-header h3{margin:0;line-height:30px}.modal-body{position:relative;overflow-y:auto;max-height:400px;padding:15px}.modal-form{margin-bottom:0}.modal-footer{padding:14px 15px 15px;margin-bottom:0;text-align:right;background-color:#f5f5f5;border-top:1px solid #ddd;-webkit-border-radius:0 0 6px 6px;-moz-border-radius:0 0 6px 6px;border-radius:0 0 6px 6px;-webkit-box-shadow:inset 0 1px 0#fff;-moz-box-shadow:inset 0 1px 0#fff;box-shadow:inset 0 1px 0#fff;*zoom:1}.modal-footer:before,.modal-footer:after{display:table;content:"";line-height:0}.modal-footer:after{clear:both}.modal-footer .btn + .btn{margin-left:5px;margin-bottom:0}.modal-footer .btn-group .btn + .btn{margin-left:-1px}.modal-footer .btn-block + .btn-block{margin-left:0}.tooltip{position:absolute;z-index:1030;display:block;visibility:visible;font-size:11px;line-height:1.4;opacity:0;filter:alpha(opacity=0)}.tooltip.in{opacity:.8;filter:alpha(opacity=80)}.tooltip.top{margin-top:-3px;padding:5px 0}.tooltip.right{margin-left:3px;padding:0 5px}.tooltip.bottom{margin-top:3px;padding:5px 0}.tooltip.left{margin-left:-3px;padding:0 5px}.tooltip-inner{max-width:200px;padding:8px;color:#fff;text-align:center;text-decoration:none;background-color:#000;-webkit-border-radius:4px;-moz-border-radius:4px;border-radius:4px}.tooltip-arrow{position:absolute;width:0;height:0;border-color:transparent;border-style:solid}.tooltip.top .tooltip-arrow{bottom:0;left:50%;margin-left:-5px;border-width:5px 5px 0;border-top-color:#000}.tooltip.right .tooltip-arrow{top:50%;left:0;margin-top:-5px;border-width:5px 5px 5px 0;border-right-color:#000}.tooltip.left .tooltip-arrow{top:50%;right:0;margin-top:-5px;border-width:5px 0 5px 5px;border-left-color:#000}.tooltip.bottom .tooltip-arrow{top:0;left:50%;margin-left:-5px;border-width:0 5px 5px;border-bottom-color:#000}.popover{position:absolute;top:0;left:0;z-index:1030;display:none;max-width:276px;padding:1px;text-align:left;background-color:#fff;-webkit-background-clip:padding-box;-moz-background-clip:padding;background-clip:padding-box;border:1px solid #ccc;border:1px solid rgba(0,0,0,0.2);-webkit-border-radius:6px;-moz-border-radius:6px;border-radius:6px;-webkit-box-shadow:0 5px 10px rgba(0,0,0,0.2);-moz-box-shadow:0 5px 10px rgba(0,0,0,0.2);box-shadow:0 5px 10px rgba(0,0,0,0.2);white-space:normal}.popover.top{margin-top:-10px}.popover.right{margin-left:10px}.popover.bottom{margin-top:10px}.popover.left{margin-left:-10px}.popover-title{margin:0;padding:8px 14px;font-size:14px;font-weight:400;line-height:18px;background-color:#f7f7f7;border-bottom:1px solid #ebebeb;-webkit-border-radius:5px 5px 0 0;-moz-border-radius:5px 5px 0 0;border-radius:5px 5px 0 0}.popover-title:empty{display:none}.popover-content{padding:9px 14px}.popover .arrow,.popover .arrow:after{position:absolute;display:block;width:0;height:0;border-color:transparent;border-style:solid}.popover .arrow{border-width:11px}.popover .arrow:after{border-width:10px;content:""}.popover.top .arrow{left:50%;margin-left:-11px;border-bottom-width:0;border-top-color:#999;border-top-color:rgba(0,0,0,0.25);bottom:-11px}.popover.top .arrow:after{bottom:1px;margin-left:-10px;border-bottom-width:0;border-top-color:#fff}.popover.right .arrow{top:50%;left:-11px;margin-top:-11px;border-left-width:0;border-right-color:#999;border-right-color:rgba(0,0,0,0.25)}.popover.right .arrow:after{left:1px;bottom:-10px;border-left-width:0;border-right-color:#fff}.popover.bottom .arrow{left:50%;margin-left:-11px;border-top-width:0;border-bottom-color:#999;border-bottom-color:rgba(0,0,0,0.25);top:-11px}.popover.bottom .arrow:after{top:1px;margin-left:-10px;border-top-width:0;border-bottom-color:#fff}.popover.left .arrow{top:50%;right:-11px;margin-top:-11px;border-right-width:0;border-left-color:#999;border-left-color:rgba(0,0,0,0.25)}.popover.left .arrow:after{right:1px;border-right-width:0;border-left-color:#fff;bottom:-10px}.thumbnails{margin-left:-20px;list-style:none;*zoom:1}.thumbnails:before,.thumbnails:after{display:table;content:"";line-height:0}.thumbnails:after{clear:both}.row-fluid .thumbnails{margin-left:0}.thumbnails > li{float:left;margin-bottom:20px;margin-left:20px}.thumbnail{display:block;padding:4px;line-height:20px;border:1px solid #ddd;-webkit-border-radius:4px;-moz-border-radius:4px;border-radius:4px;-webkit-box-shadow:0 1px 3px rgba(0,0,0,0.055);-moz-box-shadow:0 1px 3px rgba(0,0,0,0.055);box-shadow:0 1px 3px rgba(0,0,0,0.055);-webkit-transition:all .2s ease-in-out;-moz-transition:all .2s ease-in-out;-o-transition:all .2s ease-in-out;transition:all .2s ease-in-out}a.thumbnail:hover,a.thumbnail:focus{border-color:#1d8835;-webkit-box-shadow:0 1px 4px rgba(0,105,214,0.25);-moz-box-shadow:0 1px 4px rgba(0,105,214,0.25);box-shadow:0 1px 4px rgba(0,105,214,0.25)}.thumbnail > img{display:block;max-width:100%;margin-left:auto;margin-right:auto}.thumbnail .caption{padding:9px;color:#555}.label,.badge{display:inline-block;padding:2px 4px;font-size:11.844px;font-weight:700;line-height:14px;color:#fff;vertical-align:baseline;white-space:nowrap;text-shadow:0 -1px 0 rgba(0,0,0,0.25);background-color:#999}.label{-webkit-border-radius:3px;-moz-border-radius:3px;border-radius:3px}.badge{padding-left:9px;padding-right:9px;-webkit-border-radius:9px;-moz-border-radius:9px;border-radius:9px}.label:empty,.badge:empty{display:none}a.label:hover,a.label:focus,a.badge:hover,a.badge:focus{color:#fff;text-decoration:none;cursor:pointer}.label-important,.badge-important{background-color:#b94a48}.label-important[href],.badge-important[href]{background-color:#953b39}.label-warning,.badge-warning{background-color:#f89406}.label-warning[href],.badge-warning[href]{background-color:#c67605}.label-success,.badge-success{background-color:#468847}.label-success[href],.badge-success[href]{background-color:#356635}.label-info,.badge-info{background-color:#3a87ad}.label-info[href],.badge-info[href]{background-color:#2d6987}.label-inverse,.badge-inverse{background-color:#333}.label-inverse[href],.badge-inverse[href]{background-color:#1a1a1a}.btn .label,.btn .badge{position:relative;top:-1px}.btn-mini .label,.btn-mini .badge{top:0}@-webkit-keyframes progress-bar-stripes{from{background-position:40px 0}to{background-position:0 0}}@-moz-keyframes progress-bar-stripes{from{background-position:40px 0}to{background-position:0 0}}@-ms-keyframes progress-bar-stripes{from{background-position:40px 0}to{background-position:0 0}}@-o-keyframes progress-bar-stripes{from{background-position:0 0}to{background-position:40px 0}}@keyframes progress-bar-stripes{from{background-position:40px 0}to{background-position:0 0}}.progress{overflow:hidden;height:20px;margin-bottom:20px;background-color:#f7f7f7;background-image:-moz-linear-gradient(top,#f5f5f5,#f9f9f9);background-image:-webkit-gradient(linear,0 0,0 100%,from(#f5f5f5),to(#f9f9f9));background-image:-webkit-linear-gradient(top,#f5f5f5,#f9f9f9);background-image:-o-linear-gradient(top,#f5f5f5,#f9f9f9);background-image:linear-gradient(to bottom,#f5f5f5,#f9f9f9);background-repeat:repeat-x;filter:progid:DXImageTransform.Microsoft.gradient(startColorstr='#fff5f5f5',endColorstr='#fff9f9f9',GradientType=0);-webkit-box-shadow:inset 0 1px 2px rgba(0,0,0,0.1);-moz-box-shadow:inset 0 1px 2px rgba(0,0,0,0.1);box-shadow:inset 0 1px 2px rgba(0,0,0,0.1);-webkit-border-radius:4px;-moz-border-radius:4px;border-radius:4px}.progress .bar{width:0;height:100%;color:#fff;float:left;font-size:12px;text-align:center;text-shadow:0 -1px 0 rgba(0,0,0,0.25);background-color:#0e90d2;background-image:-moz-linear-gradient(top,#149bdf,#0480be);background-image:-webkit-gradient(linear,0 0,0 100%,from(#149bdf),to(#0480be));background-image:-webkit-linear-gradient(top,#149bdf,#0480be);background-image:-o-linear-gradient(top,#149bdf,#0480be);background-image:linear-gradient(to bottom,#149bdf,#0480be);background-repeat:repeat-x;filter:progid:DXImageTransform.Microsoft.gradient(startColorstr='#ff149bdf',endColorstr='#ff0480be',GradientType=0);-webkit-box-shadow:inset 0 -1px 0 rgba(0,0,0,0.15);-moz-box-shadow:inset 0 -1px 0 rgba(0,0,0,0.15);box-shadow:inset 0 -1px 0 rgba(0,0,0,0.15);-webkit-box-sizing:border-box;-moz-box-sizing:border-box;box-sizing:border-box;-webkit-transition:width .6s ease;-moz-transition:width .6s ease;-o-transition:width .6s ease;transition:width .6s ease}.progress .bar + .bar{-webkit-box-shadow:inset 1px 0 0 rgba(0,0,0,.15),inset 0 -1px 0 rgba(0,0,0,.15);-moz-box-shadow:inset 1px 0 0 rgba(0,0,0,.15),inset 0 -1px 0 rgba(0,0,0,.15);box-shadow:inset 1px 0 0 rgba(0,0,0,.15),inset 0 -1px 0 rgba(0,0,0,.15)}.progress-striped .bar{background-color:#149bdf;background-image:-webkit-gradient(linear,0 100%,100% 0,color-stop(0.25,rgba(255,255,255,0.15)),color-stop(0.25,transparent),color-stop(0.5,transparent),color-stop(0.5,rgba(255,255,255,0.15)),color-stop(0.75,rgba(255,255,255,0.15)),color-stop(0.75,transparent),to(transparent));background-image:-webkit-linear-gradient(45deg,rgba(255,255,255,0.15) 25%,transparent 25%,transparent 50%,rgba(255,255,255,0.15) 50%,rgba(255,255,255,0.15) 75%,transparent 75%,transparent);background-image:-moz-linear-gradient(45deg,rgba(255,255,255,0.15) 25%,transparent 25%,transparent 50%,rgba(255,255,255,0.15) 50%,rgba(255,255,255,0.15) 75%,transparent 75%,transparent);background-image:-o-linear-gradient(45deg,rgba(255,255,255,0.15) 25%,transparent 25%,transparent 50%,rgba(255,255,255,0.15) 50%,rgba(255,255,255,0.15) 75%,transparent 75%,transparent);background-image:linear-gradient(45deg,rgba(255,255,255,0.15) 25%,transparent 25%,transparent 50%,rgba(255,255,255,0.15) 50%,rgba(255,255,255,0.15) 75%,transparent 75%,transparent);-webkit-background-size:40px 40px;-moz-background-size:40px 40px;-o-background-size:40px 40px;background-size:40px 40px}.progress.active .bar{-webkit-animation:progress-bar-stripes 2s linear infinite;-moz-animation:progress-bar-stripes 2s linear infinite;-ms-animation:progress-bar-stripes 2s linear infinite;-o-animation:progress-bar-stripes 2s linear infinite;animation:progress-bar-stripes 2s linear infinite}.progress-danger .bar,.progress .bar-danger{background-color:#dd514c;background-image:-moz-linear-gradient(top,#ee5f5b,#c43c35);background-image:-webkit-gradient(linear,0 0,0 100%,from(#ee5f5b),to(#c43c35));background-image:-webkit-linear-gradient(top,#ee5f5b,#c43c35);background-image:-o-linear-gradient(top,#ee5f5b,#c43c35);background-image:linear-gradient(to bottom,#ee5f5b,#c43c35);background-repeat:repeat-x;filter:progid:DXImageTransform.Microsoft.gradient(startColorstr='#ffee5f5b',endColorstr='#ffc43c35',GradientType=0)}.progress-danger.progress-striped .bar,.progress-striped .bar-danger{background-color:#ee5f5b;background-image:-webkit-gradient(linear,0 100%,100% 0,color-stop(0.25,rgba(255,255,255,0.15)),color-stop(0.25,transparent),color-stop(0.5,transparent),color-stop(0.5,rgba(255,255,255,0.15)),color-stop(0.75,rgba(255,255,255,0.15)),color-stop(0.75,transparent),to(transparent));background-image:-webkit-linear-gradient(45deg,rgba(255,255,255,0.15) 25%,transparent 25%,transparent 50%,rgba(255,255,255,0.15) 50%,rgba(255,255,255,0.15) 75%,transparent 75%,transparent);background-image:-moz-linear-gradient(45deg,rgba(255,255,255,0.15) 25%,transparent 25%,transparent 50%,rgba(255,255,255,0.15) 50%,rgba(255,255,255,0.15) 75%,transparent 75%,transparent);background-image:-o-linear-gradient(45deg,rgba(255,255,255,0.15) 25%,transparent 25%,transparent 50%,rgba(255,255,255,0.15) 50%,rgba(255,255,255,0.15) 75%,transparent 75%,transparent);background-image:linear-gradient(45deg,rgba(255,255,255,0.15) 25%,transparent 25%,transparent 50%,rgba(255,255,255,0.15) 50%,rgba(255,255,255,0.15) 75%,transparent 75%,transparent)}.progress-success .bar,.progress .bar-success{background-color:#5eb95e;background-image:-moz-linear-gradient(top,#62c462,#57a957);background-image:-webkit-gradient(linear,0 0,0 100%,from(#62c462),to(#57a957));background-image:-webkit-linear-gradient(top,#62c462,#57a957);background-image:-o-linear-gradient(top,#62c462,#57a957);background-image:linear-gradient(to bottom,#62c462,#57a957);background-repeat:repeat-x;filter:progid:DXImageTransform.Microsoft.gradient(startColorstr='#ff62c462',endColorstr='#ff57a957',GradientType=0)}.progress-success.progress-striped .bar,.progress-striped .bar-success{background-color:#62c462;background-image:-webkit-gradient(linear,0 100%,100% 0,color-stop(0.25,rgba(255,255,255,0.15)),color-stop(0.25,transparent),color-stop(0.5,transparent),color-stop(0.5,rgba(255,255,255,0.15)),color-stop(0.75,rgba(255,255,255,0.15)),color-stop(0.75,transparent),to(transparent));background-image:-webkit-linear-gradient(45deg,rgba(255,255,255,0.15) 25%,transparent 25%,transparent 50%,rgba(255,255,255,0.15) 50%,rgba(255,255,255,0.15) 75%,transparent 75%,transparent);background-image:-moz-linear-gradient(45deg,rgba(255,255,255,0.15) 25%,transparent 25%,transparent 50%,rgba(255,255,255,0.15) 50%,rgba(255,255,255,0.15) 75%,transparent 75%,transparent);background-image:-o-linear-gradient(45deg,rgba(255,255,255,0.15) 25%,transparent 25%,transparent 50%,rgba(255,255,255,0.15) 50%,rgba(255,255,255,0.15) 75%,transparent 75%,transparent);background-image:linear-gradient(45deg,rgba(255,255,255,0.15) 25%,transparent 25%,transparent 50%,rgba(255,255,255,0.15) 50%,rgba(255,255,255,0.15) 75%,transparent 75%,transparent)}.progress-info .bar,.progress .bar-info{background-color:#4bb1cf;background-image:-moz-linear-gradient(top,#5bc0de,#339bb9);background-image:-webkit-gradient(linear,0 0,0 100%,from(#5bc0de),to(#339bb9));background-image:-webkit-linear-gradient(top,#5bc0de,#339bb9);background-image:-o-linear-gradient(top,#5bc0de,#339bb9);background-image:linear-gradient(to bottom,#5bc0de,#339bb9);background-repeat:repeat-x;filter:progid:DXImageTransform.Microsoft.gradient(startColorstr='#ff5bc0de',endColorstr='#ff339bb9',GradientType=0)}.progress-info.progress-striped .bar,.progress-striped .bar-info{background-color:#5bc0de;background-image:-webkit-gradient(linear,0 100%,100% 0,color-stop(0.25,rgba(255,255,255,0.15)),color-stop(0.25,transparent),color-stop(0.5,transparent),color-stop(0.5,rgba(255,255,255,0.15)),color-stop(0.75,rgba(255,255,255,0.15)),color-stop(0.75,transparent),to(transparent));background-image:-webkit-linear-gradient(45deg,rgba(255,255,255,0.15) 25%,transparent 25%,transparent 50%,rgba(255,255,255,0.15) 50%,rgba(255,255,255,0.15) 75%,transparent 75%,transparent);background-image:-moz-linear-gradient(45deg,rgba(255,255,255,0.15) 25%,transparent 25%,transparent 50%,rgba(255,255,255,0.15) 50%,rgba(255,255,255,0.15) 75%,transparent 75%,transparent);background-image:-o-linear-gradient(45deg,rgba(255,255,255,0.15) 25%,transparent 25%,transparent 50%,rgba(255,255,255,0.15) 50%,rgba(255,255,255,0.15) 75%,transparent 75%,transparent);background-image:linear-gradient(45deg,rgba(255,255,255,0.15) 25%,transparent 25%,transparent 50%,rgba(255,255,255,0.15) 50%,rgba(255,255,255,0.15) 75%,transparent 75%,transparent)}.progress-warning .bar,.progress .bar-warning{background-color:#faa732;background-image:-moz-linear-gradient(top,#fbb450,#f89406);background-image:-webkit-gradient(linear,0 0,0 100%,from(#fbb450),to(#f89406));background-image:-webkit-linear-gradient(top,#fbb450,#f89406);background-image:-o-linear-gradient(top,#fbb450,#f89406);background-image:linear-gradient(to bottom,#fbb450,#f89406);background-repeat:repeat-x;filter:progid:DXImageTransform.Microsoft.gradient(startColorstr='#fffbb450',endColorstr='#fff89406',GradientType=0)}.progress-warning.progress-striped .bar,.progress-striped .bar-warning{background-color:#fbb450;background-image:-webkit-gradient(linear,0 100%,100% 0,color-stop(0.25,rgba(255,255,255,0.15)),color-stop(0.25,transparent),color-stop(0.5,transparent),color-stop(0.5,rgba(255,255,255,0.15)),color-stop(0.75,rgba(255,255,255,0.15)),color-stop(0.75,transparent),to(transparent));background-image:-webkit-linear-gradient(45deg,rgba(255,255,255,0.15) 25%,transparent 25%,transparent 50%,rgba(255,255,255,0.15) 50%,rgba(255,255,255,0.15) 75%,transparent 75%,transparent);background-image:-moz-linear-gradient(45deg,rgba(255,255,255,0.15) 25%,transparent 25%,transparent 50%,rgba(255,255,255,0.15) 50%,rgba(255,255,255,0.15) 75%,transparent 75%,transparent);background-image:-o-linear-gradient(45deg,rgba(255,255,255,0.15) 25%,transparent 25%,transparent 50%,rgba(255,255,255,0.15) 50%,rgba(255,255,255,0.15) 75%,transparent 75%,transparent);background-image:linear-gradient(45deg,rgba(255,255,255,0.15) 25%,transparent 25%,transparent 50%,rgba(255,255,255,0.15) 50%,rgba(255,255,255,0.15) 75%,transparent 75%,transparent)}.accordion{margin-bottom:20px}.accordion-group{margin-bottom:2px;border:1px solid #e5e5e5;-webkit-border-radius:4px;-moz-border-radius:4px;border-radius:4px}.accordion-heading{border-bottom:0}.accordion-heading .accordion-toggle{display:block;padding:8px 15px}.accordion-toggle{cursor:pointer}.accordion-inner{padding:9px 15px;border-top:1px solid #e5e5e5}.carousel{position:relative;margin-bottom:20px;line-height:1}.carousel-inner{overflow:hidden;width:100%;position:relative}.carousel-inner > .item{display:none;position:relative;-webkit-transition:.6s ease-in-out left;-moz-transition:.6s ease-in-out left;-o-transition:.6s ease-in-out left;transition:.6s ease-in-out left}.carousel-inner > .item > img,.carousel-inner > .item > a > img{display:block;line-height:1}.carousel-inner > .active,.carousel-inner > .next,.carousel-inner > .prev{display:block}.carousel-inner > .active{left:0}.carousel-inner > .next,.carousel-inner > .prev{position:absolute;top:0;width:100%}.carousel-inner > .next{left:100%}.carousel-inner > .prev{left:-100%}.carousel-inner > .next.left,.carousel-inner > .prev.right{left:0}.carousel-inner > .active.left{left:-100%}.carousel-inner > .active.right{left:100%}.carousel-control{position:absolute;top:40%;left:15px;width:40px;height:40px;margin-top:-20px;font-size:60px;font-weight:100;line-height:30px;color:#fff;text-align:center;background:#222;border:3px solid#fff;-webkit-border-radius:23px;-moz-border-radius:23px;border-radius:23px;opacity:.5;filter:alpha(opacity=50)}.carousel-control.right{left:auto;right:15px}.carousel-control:hover,.carousel-control:focus{color:#fff;text-decoration:none;opacity:.9;filter:alpha(opacity=90)}.carousel-indicators{position:absolute;top:15px;right:15px;z-index:5;margin:0;list-style:none}.carousel-indicators li{display:block;float:left;width:10px;height:10px;margin-left:5px;text-indent:-999px;background-color:#ccc;background-color:rgba(255,255,255,0.25);border-radius:5px}.carousel-indicators .active{background-color:#fff}.carousel-caption{position:absolute;left:0;right:0;bottom:0;padding:15px;background:#333;background:rgba(0,0,0,0.75)}.carousel-caption h4,.carousel-caption p{color:#fff;line-height:20px}.carousel-caption h4{margin:0 0 5px}.carousel-caption p{margin-bottom:0}.hero-unit{padding:60px;margin-bottom:30px;font-size:18px;font-weight:200;line-height:30px;color:inherit;background-color:#eee;-webkit-border-radius:6px;-moz-border-radius:6px;border-radius:6px}.hero-unit h1{margin-bottom:0;font-size:60px;line-height:1;color:inherit;letter-spacing:-1px}.hero-unit li{line-height:30px}.pull-right{float:right}.pull-left{float:left}.hide{display:none}.show{display:block}.invisible{visibility:hidden}.affix{position:fixed}.container,.navbar .container{padding-left:20px;padding-right:20px;width:auto;min-width:320px;max-width:1400px}.navbar .brand{font-size:32px;line-height:32px;padding:16px 20px 12px;font-weight:700;color:#ddd;text-shadow:0 -1px 0 rgba(0,0,0,0.25),0 1px 0#fff,0 0 30px rgba(0,0,0,0.125);-webkit-transition:color .1s linear;-moz-transition:color .1s linear;-o-transition:color .1s linear;transition:color .1s linear}.navbar .brand:hover{color:#1d8835}.navbar .nav > li > a{min-height:18px}.navbar .nav li.dropdown .dropdown-toggle{padding:20px 10px 21px 20px;white-space:nowrap}.navbar .nav li.dropdown > .dropdown-toggle,.navbar .nav li.dropdown.open > .dropdown-toggle,.navbar .nav li.dropdown.active > .dropdown-toggle{background-color:transparent}.navbar .nav .dropdown-menu li a{padding-right:4em;position:relative}.navbar .nav .dropdown-menu li a span{padding:0 6px;display:inline-block;position:absolute;top:50%;right:10px;margin-top:-8px;-webkit-border-radius:8px;-moz-border-radius:8px;border-radius:8px;line-height:16px;color:#666;background-color:rgba(0,0,0,0.1);-webkit-box-shadow:inset 0 1px 0 rgba(0,0,0,0.2),0 1px 0 rgba(255,255,255,0.2);-moz-box-shadow:inset 0 1px 0 rgba(0,0,0,0.2),0 1px 0 rgba(255,255,255,0.2);box-shadow:inset 0 1px 0 rgba(0,0,0,0.2),0 1px 0 rgba(255,255,255,0.2)}.navbar .nav .dropdown-menu li a:hover span{color:#DDD}.navbar .nav .dropdown-menu li.active a span{color:#CCC;background-color:rgba(0,0,0,0.2)}.navbar form{padding-left:20px;margin:15px 0 0 -10px}.navbar .control-group{margin-bottom:0}code,pre{font-family:'Source Code Pro',monospace}.navbar-fixed-top .navbar-inner,.navbar-static-top .navbar-inner{-webkit-box-shadow:0 1px 10px rgba(0,0,0,0.1);-moz-box-shadow:0 1px 10px rgba(0,0,0,0.1);box-shadow:0 1px 10px rgba(0,0,0,0.1)}textarea:focus,input[type="text"]:focus,input[type="password"]:focus,input[type="datetime"]:focus,input[type="datetime-local"]:focus,input[type="date"]:focus,input[type="month"]:focus,input[type="time"]:focus,input[type="week"]:focus,input[type="number"]:focus,input[type="email"]:focus,input[type="url"]:focus,input[type="search"]:focus,input[type="tel"]:focus,input[type="color"]:focus,.uneditable-input:focus{border-color:rgba(29,136,53,0.8);-webkit-box-shadow:inset 0 1px 1px rgba(0,0,0,.075),0 0 8px rgba(29,136,53,0.6);-moz-box-shadow:inset 0 1px 1px rgba(0,0,0,.075),0 0 8px rgba(29,136,53,0.6);box-shadow:inset 0 1px 1px rgba(0,0,0,.075),0 0 8px rgba(29,136,53,0.6)}.nav .dropdown,.navbar-search{background-color:transparent;background-position:center left;background-repeat:no-repeat}.navbar-search{background-position:left -1px}.popover-title{font-size:18px}.confirm-modal{width:420px;margin-left:-210px}.confirm-modal .confirm-input{width:97%}html,body{color:#111;background-color:#D3D3D3}h1,h2,h3,a.brand,#footer p{font-family:"Rokkitt",serif;font-weight:700}noscript h1{font-size:2.2em;text-align:center;margin:80px 40px}::-moz-selection{background:#b4d6bc;text-shadow:none}::-webkit-selection{background:#b4d6bc;text-shadow:none}::selection{background:#b4d6bc;text-shadow:none}html,body{margin:0;padding:0}body{padding-top:60px}#alerts{margin-top:20px}#footer{font-weight:400;text-align:center}#footer a.keyboard-shortcuts:link,#footer a.keyboard-shortcuts:visited{color:#888}#footer a.keyboard-shortcuts:link img,#footer a.keyboard-shortcuts:visited img{opacity:.5;filter:alpha(opacity=50)}#footer a.keyboard-shortcuts:hover,#footer a.keyboard-shortcuts:active{color:#666}#footer a.keyboard-shortcuts:hover img,#footer a.keyboard-shortcuts:active img{opacity:1;filter:alpha(opacity=100)}#footer a.keyboard-shortcuts img{line-height:1px;vertical-align:text-top;height:11px;width:19px}.navbar .servers{display:none}.navbar .nav-section{display:none}body.section-databases .navbar .nav-section.server,body.section-collections .navbar .nav-section.server,body.section-collections .navbar .nav-section.database,body.section-documents .navbar .nav-section.server,body.section-documents .navbar .nav-section.database,body.section-documents .navbar .nav-section.collection,body.section-document .navbar .nav-section.server,body.section-document .navbar .nav-section.database,body.section-document .navbar .nav-section.collection{display:block}.navbar form{display:none}body.section-documents .navbar form,body.section-document .navbar form{display:block}.navbar .form-actions label{margin-top:15px}html.textoverflow .navbar .nav-section > a{max-width:8em;overflow:hidden;text-overflow:ellipsis}.navbar-search{padding-bottom:16px}.navbar-search .grippie{position:absolute;bottom:2px;left:50%;margin-left:-5px;clear:both;display:block;height:12px;width:30px;background-color:transparent;background-position:center center;background-repeat:repeat-x;border:none;cursor:row-resize;opacity:.5;filter:alpha(opacity=50)}.navbar-search .grippie:hover{opacity:1;filter:alpha(opacity=100)}.navbar-search .search-advanced{display:none;position:absolute;top:0;left:0;right:0;bottom:10px}.navbar-search .search-advanced .well{position:absolute;top:0;left:0;right:0;bottom:30px;padding:0;overflow:hidden}.navbar-search .search-advanced.focused .well{border-color:rgba(29,136,53,0.8);-webkit-box-shadow:inset 0 1px 1px rgba(0,0,0,.075),0 0 8px rgba(29,136,53,0.6);-moz-box-shadow:inset 0 1px 1px rgba(0,0,0,.075),0 0 8px rgba(29,136,53,0.6);box-shadow:inset 0 1px 1px rgba(0,0,0,.075),0 0 8px rgba(29,136,53,0.6)}.navbar-search .search-advanced .form-actions{position:absolute;left:0;right:0;bottom:0;padding:0;margin:-20px 0 5px;border-top:none;background:transparent}.navbar-search .search-advanced .form-actions .btn{float:right;margin-left:5px}.navbar-search.expanded{position:relative;clear:both;float:none;margin:0 20px;padding:0;background-image:none;min-height:120px}.navbar-search.expanded .grippie{margin-left:-15px}.navbar-search.expanded input.search-query{display:none}.navbar-search.expanded .search-advanced{display:block}.masthead{position:relative;padding:40px 0;color:#fff;text-shadow:0 1px 3px rgba(0,0,0,0.4),0 0 30px rgba(0,0,0,0.1);background:-webkit-radial-gradient(#115120 25%,transparent 26%) 0 0,-webkit-radial-gradient(#115120 25%,transparent 26%) 16px 16px,-webkit-radial-gradient(rgba(0,0,0,0.2) 25%,transparent 26%) 0 -1px,-webkit-radial-gradient(rgba(0,0,0,0.2) 25%,transparent 26%) 16px 15px,-webkit-radial-gradient(rgba(255,255,255,0.1) 25%,transparent 26%) 0 1px,-webkit-radial-gradient(rgba(255,255,255,0.1) 25%,transparent 26%) 16px 17px;background:-moz-radial-gradient(#115120 25%,transparent 26%) 0 0,-moz-radial-gradient(#115120 25%,transparent 26%) 16px 16px,-moz-radial-gradient(rgba(0,0,0,0.2) 25%,transparent 26%) 0 -1px,-moz-radial-gradient(rgba(0,0,0,0.2) 25%,transparent 26%) 16px 15px,-moz-radial-gradient(rgba(255,255,255,0.1) 25%,transparent 26%) 0 1px,-moz-radial-gradient(rgba(255,255,255,0.1) 25%,transparent 26%) 16px 17px;background:-ms-radial-gradient(#115120 25%,transparent 26%) 0 0,-ms-radial-gradient(#115120 25%,transparent 26%) 16px 16px,-ms-radial-gradient(rgba(0,0,0,0.2) 25%,transparent 26%) 0 -1px,-ms-radial-gradient(rgba(0,0,0,0.2) 25%,transparent 26%) 16px 15px,-ms-radial-gradient(rgba(255,255,255,0.1) 25%,transparent 26%) 0 1px,-ms-radial-gradient(rgba(255,255,255,0.1) 25%,transparent 26%) 16px 17px;background:-o-radial-gradient(#115120 25%,transparent 26%) 0 0,-o-radial-gradient(#115120 25%,transparent 26%) 16px 16px,-o-radial-gradient(rgba(0,0,0,0.2) 25%,transparent 26%) 0 -1px,-o-radial-gradient(rgba(0,0,0,0.2) 25%,transparent 26%) 16px 15px,-o-radial-gradient(rgba(255,255,255,0.1) 25%,transparent 26%) 0 1px,-o-radial-gradient(rgba(255,255,255,0.1) 25%,transparent 26%) 16px 17px;background:radial-gradient(#115120 25%,transparent 26%) 0 0,radial-gradient(#115120 25%,transparent 26%) 16px 16px,radial-gradient(rgba(0,0,0,0.2) 25%,transparent 26%) 0 -1px,radial-gradient(rgba(0,0,0,0.2) 25%,transparent 26%) 16px 15px,radial-gradient(rgba(255,255,255,0.1) 25%,transparent 26%) 0 1px,radial-gradient(rgba(255,255,255,0.1) 25%,transparent 26%) 16px 17px;-webkit-background-size:32px 30px;-moz-background-size:32px 30px;-ms-background-size:32px 30px;-o-background-size:32px 30px;background-size:32px 30px;background-color:#145e25;-webkit-box-shadow:inset 0 3px 7px rgba(0,0,0,.2),inset 0 -3px 7px rgba(0,0,0,.2);-moz-box-shadow:inset 0 3px 7px rgba(0,0,0,.2),inset 0 -3px 7px rgba(0,0,0,.2);box-shadow:inset 0 3px 7px rgba(0,0,0,.2),inset 0 -3px 7px rgba(0,0,0,.2)}.masthead .container{position:relative;z-index:2}.masthead:after{content:'';display:block;position:absolute;top:0;right:0;bottom:0;left:0;background-color:rgba(255,255,255,0.01);background-image:-moz-linear-gradient(left,rgba(0,0,0,0.5),rgba(255,255,255,0.01));background-image:-webkit-gradient(linear,0 0,100% 0,from(rgba(0,0,0,0.5)),to(rgba(255,255,255,0.01)));background-image:-webkit-linear-gradient(left,rgba(0,0,0,0.5),rgba(255,255,255,0.01));background-image:-o-linear-gradient(left,rgba(0,0,0,0.5),rgba(255,255,255,0.01));background-image:linear-gradient(to right,rgba(0,0,0,0.5),rgba(255,255,255,0.01));background-repeat:repeat-x;filter:progid:DXImageTransform.Microsoft.gradient(startColorstr='#80000000',endColorstr='#03ffffff',GradientType=1)}.masthead h1{font-size:60px;font-weight:700;letter-spacing:-1px;line-height:1}.masthead p{font-size:24px;line-height:1.25;margin-bottom:20px;font-weight:300}.masthead.epic{text-align:center;padding:70px 80px}.masthead.epic h1{font-size:120px}.masthead.epic h2{font-size:80px}.masthead.epic p{font-size:40px;font-weight:200;margin-bottom:30px}.masthead.error{background:-webkit-radial-gradient(#8a3635 25%,transparent 26%) 0 0,-webkit-radial-gradient(#8a3635 25%,transparent 26%) 16px 16px,-webkit-radial-gradient(rgba(0,0,0,0.2) 25%,transparent 26%) 0 -1px,-webkit-radial-gradient(rgba(0,0,0,0.2) 25%,transparent 26%) 16px 15px,-webkit-radial-gradient(rgba(255,255,255,0.1) 25%,transparent 26%) 0 1px,-webkit-radial-gradient(rgba(255,255,255,0.1) 25%,transparent 26%) 16px 17px;background:-moz-radial-gradient(#8a3635 25%,transparent 26%) 0 0,-moz-radial-gradient(#8a3635 25%,transparent 26%) 16px 16px,-moz-radial-gradient(rgba(0,0,0,0.2) 25%,transparent 26%) 0 -1px,-moz-radial-gradient(rgba(0,0,0,0.2) 25%,transparent 26%) 16px 15px,-moz-radial-gradient(rgba(255,255,255,0.1) 25%,transparent 26%) 0 1px,-moz-radial-gradient(rgba(255,255,255,0.1) 25%,transparent 26%) 16px 17px;background:-ms-radial-gradient(#8a3635 25%,transparent 26%) 0 0,-ms-radial-gradient(#8a3635 25%,transparent 26%) 16px 16px,-ms-radial-gradient(rgba(0,0,0,0.2) 25%,transparent 26%) 0 -1px,-ms-radial-gradient(rgba(0,0,0,0.2) 25%,transparent 26%) 16px 15px,-ms-radial-gradient(rgba(255,255,255,0.1) 25%,transparent 26%) 0 1px,-ms-radial-gradient(rgba(255,255,255,0.1) 25%,transparent 26%) 16px 17px;background:-o-radial-gradient(#8a3635 25%,transparent 26%) 0 0,-o-radial-gradient(#8a3635 25%,transparent 26%) 16px 16px,-o-radial-gradient(rgba(0,0,0,0.2) 25%,transparent 26%) 0 -1px,-o-radial-gradient(rgba(0,0,0,0.2) 25%,transparent 26%) 16px 15px,-o-radial-gradient(rgba(255,255,255,0.1) 25%,transparent 26%) 0 1px,-o-radial-gradient(rgba(255,255,255,0.1) 25%,transparent 26%) 16px 17px;background:radial-gradient(#8a3635 25%,transparent 26%) 0 0,radial-gradient(#8a3635 25%,transparent 26%) 16px 16px,radial-gradient(rgba(0,0,0,0.2) 25%,transparent 26%) 0 -1px,radial-gradient(rgba(0,0,0,0.2) 25%,transparent 26%) 16px 15px,radial-gradient(rgba(255,255,255,0.1) 25%,transparent 26%) 0 1px,radial-gradient(rgba(255,255,255,0.1) 25%,transparent 26%) 16px 17px;-webkit-background-size:32px 30px;-moz-background-size:32px 30px;-ms-background-size:32px 30px;-o-background-size:32px 30px;background-size:32px 30px;background-color:#953b39}.masthead.muted{background:-webkit-radial-gradient(#2b2b2b 25%,transparent 26%) 0 0,-webkit-radial-gradient(#2b2b2b 25%,transparent 26%) 16px 16px,-webkit-radial-gradient(rgba(0,0,0,0.2) 25%,transparent 26%) 0 -1px,-webkit-radial-gradient(rgba(0,0,0,0.2) 25%,transparent 26%) 16px 15px,-webkit-radial-gradient(rgba(255,255,255,0.1) 25%,transparent 26%) 0 1px,-webkit-radial-gradient(rgba(255,255,255,0.1) 25%,transparent 26%) 16px 17px;background:-moz-radial-gradient(#2b2b2b 25%,transparent 26%) 0 0,-moz-radial-gradient(#2b2b2b 25%,transparent 26%) 16px 16px,-moz-radial-gradient(rgba(0,0,0,0.2) 25%,transparent 26%) 0 -1px,-moz-radial-gradient(rgba(0,0,0,0.2) 25%,transparent 26%) 16px 15px,-moz-radial-gradient(rgba(255,255,255,0.1) 25%,transparent 26%) 0 1px,-moz-radial-gradient(rgba(255,255,255,0.1) 25%,transparent 26%) 16px 17px;background:-ms-radial-gradient(#2b2b2b 25%,transparent 26%) 0 0,-ms-radial-gradient(#2b2b2b 25%,transparent 26%) 16px 16px,-ms-radial-gradient(rgba(0,0,0,0.2) 25%,transparent 26%) 0 -1px,-ms-radial-gradient(rgba(0,0,0,0.2) 25%,transparent 26%) 16px 15px,-ms-radial-gradient(rgba(255,255,255,0.1) 25%,transparent 26%) 0 1px,-ms-radial-gradient(rgba(255,255,255,0.1) 25%,transparent 26%) 16px 17px;background:-o-radial-gradient(#2b2b2b 25%,transparent 26%) 0 0,-o-radial-gradient(#2b2b2b 25%,transparent 26%) 16px 16px,-o-radial-gradient(rgba(0,0,0,0.2) 25%,transparent 26%) 0 -1px,-o-radial-gradient(rgba(0,0,0,0.2) 25%,transparent 26%) 16px 15px,-o-radial-gradient(rgba(255,255,255,0.1) 25%,transparent 26%) 0 1px,-o-radial-gradient(rgba(255,255,255,0.1) 25%,transparent 26%) 16px 17px;background:radial-gradient(#2b2b2b 25%,transparent 26%) 0 0,radial-gradient(#2b2b2b 25%,transparent 26%) 16px 16px,radial-gradient(rgba(0,0,0,0.2) 25%,transparent 26%) 0 -1px,radial-gradient(rgba(0,0,0,0.2) 25%,transparent 26%) 16px 15px,radial-gradient(rgba(255,255,255,0.1) 25%,transparent 26%) 0 1px,radial-gradient(rgba(255,255,255,0.1) 25%,transparent 26%) 16px 17px;-webkit-background-size:32px 30px;-moz-background-size:32px 30px;-ms-background-size:32px 30px;-o-background-size:32px 30px;background-size:32px 30px;background-color:#333}#genghis{min-height:150px}.app-section{display:none;background-color:#fff;margin:20px 0;padding:20px;border:1px solid #AAA;-webkit-border-radius:4px;-moz-border-radius:4px;border-radius:4px;-webkit-box-shadow:0 1px 5px rgba(0,0,0,0.1),inset 0 1px 0 white;-moz-box-shadow:0 1px 5px rgba(0,0,0,0.1),inset 0 1px 0 white;box-shadow:0 1px 5px rgba(0,0,0,0.1),inset 0 1px 0 white}.app-section > header{-webkit-border-radius:4px 4px 0 0;-moz-border-radius:4px 4px 0 0;border-radius:4px 4px 0 0;margin:-20px -20px 20px;padding:9px 20px;background-color:#f5f5f5;border-bottom:1px solid #ddd;-webkit-box-shadow:inset 0 1px 0#fff;-moz-box-shadow:inset 0 1px 0#fff;box-shadow:inset 0 1px 0#fff}.app-section > header h2{font-size:24px;margin:0;line-height:30px}.app-section > .content{min-height:100px;-webkit-transition:.1s linear all;-moz-transition:.1s linear all;-o-transition:.1s linear all;transition:.1s linear all}.app-section > p:first-child{margin-top:0}.app-section > p:last-child{margin-bottom:0}.app-section.spinning{height:180px}.app-section.spinning header h2{background-color:transparent;background-position:left center;background-repeat:no-repeat;text-indent:-10000em}.app-section.spinning .controls,.app-section.spinning .add-form,.app-section.spinning .content{display:none}.app-section .details{display:none}.app-section .has-details{border-bottom:1px dotted#998;cursor:default}.add-form button.show,.add-form button.dropdown-toggle{display:none}.add-form.inactive button,.add-form.inactive input,.add-form.inactive .input-append{display:none}.add-form.inactive button.show,.add-form.inactive button.dropdown-toggle{display:inherit}.add-form.inactive .help{display:none}.add-form span.input-append .add-on{margin-right:4px}.add-form .help{cursor:default}table{width:100%;margin-bottom:20px;border:1px solid#ddd;border-collapse:separate;*border-collapse:collapse;border-left:0;-webkit-border-radius:4px;-moz-border-radius:4px;border-radius:4px}table th,table td{padding:8px;line-height:20px;text-align:left;vertical-align:top;border-top:1px solid#ddd}table th{font-weight:700}table thead th{vertical-align:bottom}table caption + thead tr:first-child th,table caption + thead tr:first-child td,table colgroup + thead tr:first-child th,table colgroup + thead tr:first-child td,table thead:first-child tr:first-child th,table thead:first-child tr:first-child td{border-top:0}table tbody + tbody{border-top:2px solid#ddd}table .table{background-color:#fff}table th,table td{border-left:1px solid#ddd}table caption + thead tr:first-child th,table caption + tbody tr:first-child th,table caption + tbody tr:first-child td,table colgroup + thead tr:first-child th,table colgroup + tbody tr:first-child th,table colgroup + tbody tr:first-child td,table thead:first-child tr:first-child th,table tbody:first-child tr:first-child th,table tbody:first-child tr:first-child td{border-top:0}table thead:first-child tr:first-child > th:first-child,table tbody:first-child tr:first-child > td:first-child,table tbody:first-child tr:first-child > th:first-child{-webkit-border-top-left-radius:4px;-moz-border-radius-topleft:4px;border-top-left-radius:4px}table thead:first-child tr:first-child > th:last-child,table tbody:first-child tr:first-child > td:last-child,table tbody:first-child tr:first-child > th:last-child{-webkit-border-top-right-radius:4px;-moz-border-radius-topright:4px;border-top-right-radius:4px}table thead:last-child tr:last-child > th:first-child,table tbody:last-child tr:last-child > td:first-child,table tbody:last-child tr:last-child > th:first-child,table tfoot:last-child tr:last-child > td:first-child,table tfoot:last-child tr:last-child > th:first-child{-webkit-border-bottom-left-radius:4px;-moz-border-radius-bottomleft:4px;border-bottom-left-radius:4px}table thead:last-child tr:last-child > th:last-child,table tbody:last-child tr:last-child > td:last-child,table tbody:last-child tr:last-child > th:last-child,table tfoot:last-child tr:last-child > td:last-child,table tfoot:last-child tr:last-child > th:last-child{-webkit-border-bottom-right-radius:4px;-moz-border-radius-bottomright:4px;border-bottom-right-radius:4px}table tfoot + tbody:last-child tr:last-child td:first-child{-webkit-border-bottom-left-radius:0;-moz-border-radius-bottomleft:0;border-bottom-left-radius:0}table tfoot + tbody:last-child tr:last-child td:last-child{-webkit-border-bottom-right-radius:0;-moz-border-radius-bottomright:0;border-bottom-right-radius:0}table caption + thead tr:first-child th:first-child,table caption + tbody tr:first-child td:first-child,table colgroup + thead tr:first-child th:first-child,table colgroup + tbody tr:first-child td:first-child{-webkit-border-top-left-radius:4px;-moz-border-radius-topleft:4px;border-top-left-radius:4px}table caption + thead tr:first-child th:last-child,table caption + tbody tr:first-child td:last-child,table colgroup + thead tr:first-child th:last-child,table colgroup + tbody tr:first-child td:last-child{-webkit-border-top-right-radius:4px;-moz-border-radius-topright:4px;border-top-right-radius:4px}table tbody tr:hover > td,table tbody tr:hover > th{background-color:#f5f5f5}table .tablesorter-header-inner{float:left}table .tablesorter-header{cursor:pointer}table .tablesorter-header:after{content:"";float:right;margin-top:7px;border-width:0 4px 4px;border-style:solid;border-color:#000 transparent;visibility:hidden}table .tablesorter-header.sorter-false{cursor:default}table .tablesorter-header.sorter-false:after{display:none}table .tablesorter-header.tablesorter-headerAsc,table .tablesorter-header.tablesorter-headerDesc{background-color:rgba(29,136,53,0.050000000000000044);text-shadow:0 1px 1px rgba(255,255,255,0.75)}table .tablesorter-header:hover:after{visibility:visible}table .tablesorter-header.tablesorter-headerDesc:after,table .tablesorter-header.tablesorter-headerDesc:hover:after{visibility:visible;opacity:.6;filter:alpha(opacity=60)}table .tablesorter-header.tablesorter-headerAsc:after{border-bottom:none;border-left:4px solid transparent;border-right:4px solid transparent;border-top:4px solid #000;visibility:visible;-webkit-box-shadow:none;-moz-box-shadow:none;box-shadow:none;opacity:.6;filter:alpha(opacity=60)}tr td.action-column{padding:7px 10px 0;text-align:right}tr td.action-column button{visibility:hidden;-webkit-transition-property:color,background,box-shadow;-moz-transition-property:color,background,box-shadow;-o-transition-property:color,background,box-shadow;transition-property:color,background,box-shadow}tr:hover td.action-column button{visibility:inherit}#servers .alert-error{padding:3px 10px;font-weight:700}#servers tr.spinning td:first-child{padding-left:35px;background-color:transparent;background-position:10px center;background-repeat:no-repeat}#servers tr input{display:none}#servers tr.editing span.name{display:none}#servers tr.editing input{display:inherit}html.no-filereader #documents .file-upload{display:none}.index-details{color:#111;list-style:none;margin:0}.index-details li{display:block;margin-bottom:5px}.stats-details,.stats-details dt,.stats-details dd{margin:0;padding:0}.stats-details dt{float:left;width:10em}.stats-details dd{margin-left:10em;text-align:right}#documents .controls{*zoom:1;margin-bottom:20px}#documents .controls:before,#documents .controls:after{display:table;content:"";line-height:0}#documents .controls:after{clear:both}#documents .add-document{float:left}#documents .pagination{margin:0}#documents .pagination li.prev a:after{content:' Previous'}#documents .pagination li.next a:before{content:'Next '}#document h2 small{font-size:12px;font-family:"Helvetica Neue",Helvetica,Arial,sans-serif;padding-left:10px}#document article h3{display:none}.document{font-family:'Source Code Pro',monospace;line-height:1.4em}.document-wrapper div.well{overflow-x:auto}.document-wrapper div.well h3{margin-top:0}.document-wrapper div.well h3 a{color:#333}.document-wrapper div.well h3 a:hover,.document-wrapper div.well h3 a:active{color:#1d8835}.document-wrapper div.well h3 small{font-size:12px;font-family:"Helvetica Neue",Helvetica,Arial,sans-serif;padding-left:10px}.document-wrapper article{position:relative}.document-wrapper article .document-actions{position:absolute;right:20px;z-index:10}.document-wrapper article .document-actions button.save,.document-wrapper article .document-actions button.cancel{display:none}.document-wrapper article .document-actions button.edit,.document-wrapper article .document-actions button.destroy,.document-wrapper article .document-actions a.grid-download,.document-wrapper article .document-actions a.grid-file{visibility:hidden}.document-wrapper article:hover .document-actions button.edit,.document-wrapper article:hover .document-actions button.destroy,.document-wrapper article:hover .document-actions a.grid-download,.document-wrapper article:hover .document-actions a.grid-file{visibility:inherit}.document-wrapper article div.well{-webkit-transition:border linear .2s,box-shadow linear .2s;-moz-transition:border linear .2s,box-shadow linear .2s;-o-transition:border linear .2s,box-shadow linear .2s;transition:border linear .2s,box-shadow linear .2s;-webkit-box-shadow:inset 0 1px 1px rgba(0,0,0,0.05);-moz-box-shadow:inset 0 1px 1px rgba(0,0,0,0.05);box-shadow:inset 0 1px 1px rgba(0,0,0,0.05)}.document-wrapper article.edit .document-actions{margin-top:20px}.document-wrapper article.edit .document-actions button.edit,.document-wrapper article.edit .document-actions button.destroy,.document-wrapper article.edit .document-actions a.grid-download,.document-wrapper article.edit .document-actions a.grid-file{display:none}.document-wrapper article.edit .document-actions button.save,.document-wrapper article.edit .document-actions button.cancel{display:inline-block}.document-wrapper article.edit div.well{padding:0;background-color:#fff;*zoom:1}.document-wrapper article.edit div.well h3{display:none}.document-wrapper article.edit div.well:before,.document-wrapper article.edit div.well:after{display:table;content:"";line-height:0}.document-wrapper article.edit div.well:after{clear:both}.document-wrapper article.edit.focused div.well{border-color:rgba(29,136,53,0.8);-webkit-box-shadow:inset 0 1px 1px rgba(0,0,0,.075),0 0 8px rgba(29,136,53,0.6);-moz-box-shadow:inset 0 1px 1px rgba(0,0,0,.075),0 0 8px rgba(29,136,53,0.6);box-shadow:inset 0 1px 1px rgba(0,0,0,.075),0 0 8px rgba(29,136,53,0.6)}.modal-editor{width:820px;margin-left:-410px}.modal-editor .wrapper,.modal-file-upload .wrapper{-webkit-border-radius:4px;-moz-border-radius:4px;border-radius:4px;border:1px solid#ccc}.modal-editor .wrapper.focused,.modal-file-upload .wrapper.focused{border:1px solid rgba(29,136,53,0.8);-webkit-box-shadow:0 0 8px rgba(29,136,53,0.6);-moz-box-shadow:0 0 8px rgba(29,136,53,0.6);box-shadow:0 0 8px rgba(29,136,53,0.6)}.modal-editor .CodeMirror-scroll,.modal-file-upload .CodeMirror-scroll{height:250px}#keyboard-shortcuts ul{*zoom:1;list-style:none;margin:0;padding:0}#keyboard-shortcuts ul:before,#keyboard-shortcuts ul:after{display:table;content:"";line-height:0}#keyboard-shortcuts ul:after{clear:both}#keyboard-shortcuts li{width:50%;float:left;list-style:none;margin:0;padding:0}#keyboard-shortcuts h4{font-size:1em;line-height:2;padding-left:2em}#keyboard-shortcuts dt,#keyboard-shortcuts dd{line-height:1.5}#keyboard-shortcuts dt{float:left;text-align:right;width:6em;margin:0 0 0 -2em;padding:0}#keyboard-shortcuts dd{margin:0 0 0 5em}.document-wrapper article h3{line-height:1;margin-bottom:10px}.document-wrapper .document{color:#111;position:relative;white-space:pre}.document-wrapper .document .null,.document-wrapper .document .bool,.document-wrapper .document .z,.document-wrapper .document .b{color:#0086b3}.document-wrapper .document .num,.document-wrapper .document .n{color:#40A070}.document-wrapper .document .quoted,.document-wrapper .document .q{color:#D20}.document-wrapper .document .quoted .string,.document-wrapper .document .q .string,.document-wrapper .document .quoted .s,.document-wrapper .document .q .s{color:#D14}.document-wrapper .document .quoted .string a:link,.document-wrapper .document .q .string a:link,.document-wrapper .document .quoted .s a:link,.document-wrapper .document .q .s a:link,.document-wrapper .document .quoted .string a:visited,.document-wrapper .document .q .string a:visited,.document-wrapper .document .quoted .s a:visited,.document-wrapper .document .q .s a:visited{color:#D14;text-decoration:underline}.document-wrapper .document .quoted .string a:hover,.document-wrapper .document .q .string a:hover,.document-wrapper .document .quoted .s a:hover,.document-wrapper .document .q .s a:hover,.document-wrapper .document .quoted .string a:active,.document-wrapper .document .q .string a:active,.document-wrapper .document .quoted .s a:active,.document-wrapper .document .q .s a:active{color:#0058E1}.document-wrapper .document .re{color:#009926}.document-wrapper .document .ref .ref-ref .v .s,.document-wrapper .document .ref .ref-db .v .s,.document-wrapper .document .ref .ref-id .v .s{cursor:pointer;border-bottom:1px dotted #D14}.document-wrapper .document .ref .ref-ref .v .s:hover,.document-wrapper .document .ref .ref-db .v .s:hover,.document-wrapper .document .ref .ref-id .v .s:hover{color:#1d8835;border-bottom:1px solid #1d8835}.document-wrapper .document .ref .ref-id .v.n{cursor:pointer;border-bottom:1px dotted #D14;border-bottom-color:#40A070}.document-wrapper .document .ref .ref-id .v.n:hover{color:#1d8835;border-bottom:1px solid #1d8835}.document-wrapper .document var{font-style:normal}.document-wrapper .document .p{position:relative}.document-wrapper .document .p .ellipsis,.document-wrapper .document .p .e{display:none;cursor:pointer}.document-wrapper .document .p .ellipsis .summary,.document-wrapper .document .p .e .summary,.document-wrapper .document .p .ellipsis q,.document-wrapper .document .p .e q{color:#998;font-style:italic}.document-wrapper .document .p .collapser,.document-wrapper .document .p .c,.document-wrapper .document .p button{display:block;cursor:pointer;position:absolute;height:16px;width:16px;left:-16px;top:0;padding:0;font-size:0;line-height:0;color:transparent;overflow:hidden}.document-wrapper .document .p .collapser:after,.document-wrapper .document .p .c:after,.document-wrapper .document .p button:after{display:block;position:absolute;left:4px;top:6px;height:0;width:0;content:' ';border:4px solid transparent;border-top-color:#c8c8bf}.document-wrapper .document .p .collapser:hover:after,.document-wrapper .document .p .c:hover:after,.document-wrapper .document .p button:hover:after,.document-wrapper .document .p .collapser:active:after,.document-wrapper .document .p .c:active:after,.document-wrapper .document .p button:active:after{border-top-color:#998}.document-wrapper .document .p button{border:none;background-color:transparent}.document-wrapper .document .p.collapsed button:after{left:6px;top:4px;border-top-color:transparent;border-left-color:#c8c8bf}.document-wrapper .document .p.collapsed button:hover:after,.document-wrapper .document .p.collapsed button:active:after{border-top-color:transparent;border-left-color:#998}.document-wrapper .document .p.collapsed .ellipsis,.document-wrapper .document .p.collapsed .e{display:inline}.document-wrapper .document .p.collapsed .collapser:after,.document-wrapper .document .p.collapsed .c:after{top:4px;border-top-color:transparent;border-left-color:#c8c8bf}.document-wrapper .document .p.collapsed .collapser:hover:after,.document-wrapper .document .p.collapsed .c:hover:after,.document-wrapper .document .p.collapsed .collapser:active:after,.document-wrapper .document .p.collapsed .c:active:after{border-top-color:transparent;border-left-color:#998}.document-wrapper .document .p.collapsed > .v{height:0;width:0;overflow:hidden;display:inline-block;visibility:hidden}.index-details li{color:#111;position:relative;white-space:pre;white-space:normal}.index-details li .null,.index-details li .bool,.index-details li .z,.index-details li .b{color:#0086b3}.index-details li .num,.index-details li .n{color:#40A070}.index-details li .quoted,.index-details li .q{color:#D20}.index-details li .quoted .string,.index-details li .q .string,.index-details li .quoted .s,.index-details li .q .s{color:#D14}.index-details li .quoted .string a:link,.index-details li .q .string a:link,.index-details li .quoted .s a:link,.index-details li .q .s a:link,.index-details li .quoted .string a:visited,.index-details li .q .string a:visited,.index-details li .quoted .s a:visited,.index-details li .q .s a:visited{color:#D14;text-decoration:underline}.index-details li .quoted .string a:hover,.index-details li .q .string a:hover,.index-details li .quoted .s a:hover,.index-details li .q .s a:hover,.index-details li .quoted .string a:active,.index-details li .q .string a:active,.index-details li .quoted .s a:active,.index-details li .q .s a:active{color:#0058E1}.index-details li .re{color:#009926}.index-details li .ref .ref-ref .v .s,.index-details li .ref .ref-db .v .s,.index-details li .ref .ref-id .v .s{cursor:pointer;border-bottom:1px dotted #D14}.index-details li .ref .ref-ref .v .s:hover,.index-details li .ref .ref-db .v .s:hover,.index-details li .ref .ref-id .v .s:hover{color:#1d8835;border-bottom:1px solid #1d8835}.index-details li .ref .ref-id .v.n{cursor:pointer;border-bottom:1px dotted #D14;border-bottom-color:#40A070}.index-details li .ref .ref-id .v.n:hover{color:#1d8835;border-bottom:1px solid #1d8835}.index-details li var{font-style:normal}.index-details li .p{position:relative}.index-details li .p .ellipsis,.index-details li .p .e{display:none;cursor:pointer}.index-details li .p .ellipsis .summary,.index-details li .p .e .summary,.index-details li .p .ellipsis q,.index-details li .p .e q{color:#998;font-style:italic}.index-details li .p .collapser,.index-details li .p .c,.index-details li .p button{display:block;cursor:pointer;position:absolute;height:16px;width:16px;left:-16px;top:0;padding:0;font-size:0;line-height:0;color:transparent;overflow:hidden}.index-details li .p .collapser:after,.index-details li .p .c:after,.index-details li .p button:after{display:block;position:absolute;left:4px;top:6px;height:0;width:0;content:' ';border:4px solid transparent;border-top-color:#c8c8bf}.index-details li .p .collapser:hover:after,.index-details li .p .c:hover:after,.index-details li .p button:hover:after,.index-details li .p .collapser:active:after,.index-details li .p .c:active:after,.index-details li .p button:active:after{border-top-color:#998}.index-details li .p button{border:none;background-color:transparent}.index-details li .p.collapsed button:after{left:6px;top:4px;border-top-color:transparent;border-left-color:#c8c8bf}.index-details li .p.collapsed button:hover:after,.index-details li .p.collapsed button:active:after{border-top-color:transparent;border-left-color:#998}.index-details li .p.collapsed .ellipsis,.index-details li .p.collapsed .e{display:inline}.index-details li .p.collapsed .collapser:after,.index-details li .p.collapsed .c:after{top:4px;border-top-color:transparent;border-left-color:#c8c8bf}.index-details li .p.collapsed .collapser:hover:after,.index-details li .p.collapsed .c:hover:after,.index-details li .p.collapsed .collapser:active:after,.index-details li .p.collapsed .c:active:after{border-top-color:transparent;border-left-color:#998}.index-details li .p.collapsed > .v{height:0;width:0;overflow:hidden;display:inline-block;visibility:hidden}.cm-s-default span.cm-keyword{color:#111}.cm-s-default span.cm-atom{color:#0086b3}.cm-s-default span.cm-number{color:#40A070}.cm-s-default span.cm-def{color:#111}.cm-s-default span.cm-variable{color:#111}.cm-s-default span.cm-variable-2{color:#111}.cm-s-default span.cm-variable-3{color:#111}.cm-s-default span.cm-property{color:#111}.cm-s-default span.cm-operator{color:#111}.cm-s-default span.cm-comment{color:#111}.cm-s-default span.cm-string{color:#D14}.cm-s-default span.cm-string-2{color:#009926}.cm-s-default span.cm-meta{color:#111}.cm-s-default span.cm-error{color:red}.cm-s-default span.cm-qualifier{color:#111}.cm-s-default span.cm-builtin{color:#111}.cm-s-default span.cm-bracket{color:#111}.cm-s-default span.cm-tag{color:#111}.cm-s-default span.cm-attribute{color:#111}.cm-s-default span.cm-header{color:#111}.cm-s-default span.cm-quote{color:#111}.cm-s-default span.cm-hr{color:#111}.cm-s-default span.cm-link{color:#1d8835}.CodeMirror-focused div.CodeMirror-selected{background:#b4d6bc}.CodeMirror{font-family:'Source Code Pro',monospace;line-height:1.4em;background-color:#fff;-webkit-border-radius:4px;-moz-border-radius:4px;border-radius:4px;-webkit-box-shadow:inset 0 1px 1px rgba(0,0,0,.075);-moz-box-shadow:inset 0 1px 1px rgba(0,0,0,.075);box-shadow:inset 0 1px 1px rgba(0,0,0,.075)}.CodeMirror .error-line{background-color:#f2dede}.CodeMirror-gutters{-webkit-border-top-left-radius:4px;-moz-border-radius-topleft:4px;border-top-left-radius:4px;-webkit-border-bottom-left-radius:4px;-moz-border-radius-bottomleft:4px;border-bottom-left-radius:4px}.welcome-links{margin:0;padding:0;list-style:none}.welcome-links li{display:inline;padding:0 10px;color:#729e7c}.welcome-links a:link,.welcome-links a:visited{color:#b9cfbd;-webkit-transition:color .2s ease-in-out;-moz-transition:color .2s ease-in-out;-o-transition:color .2s ease-in-out;transition:color .2s ease-in-out}.welcome-links a:hover,.welcome-links a:active{color:#fff}@media screen and (max-width:1200px){#documents .pagination li.next a:before{content:'Next '}#documents .pagination li.prev a:after{content:' Prev'}}@media screen and (max-width:860px),screen and (max-height:860px){.masthead.epic.welcome{padding:40px 20px}.masthead.epic.welcome h1{font-size:90px}.masthead.epic.welcome h2{font-size:60px}.masthead.epic.welcome p{font-size:24px}}@media screen and (max-width:860px){.masthead{padding:40px 20px;margin-right:-20px;margin-left:-20px}.masthead.epic{padding:40px 20px}.masthead.epic h1{font-size:90px}.masthead.epic h2{font-size:60px}.masthead.epic p{font-size:24px}.modal-editor{left:20px;right:20px;width:auto;margin-left:0}table th,table td{padding:4px 5px}table td.action-column{padding-top:2px}#documents .pagination li.prev a:after,#documents .pagination li.next a:before{content:''}#keyboard-shortcuts{width:440px;margin-left:-220px}}@media only screen and (max-width:480px),only screen and (max-height:680px){.masthead.epic.welcome h1{font-size:60px}.masthead.epic.welcome h2{font-size:40px}.masthead.epic.welcome p{font-size:20px}}@media only screen and (max-width:480px){.container{padding:0}.navbar .nav{float:none}.navbar .btn.search{display:inline-block;z-index:10}body.section-documents .navbar form,body.section-document .navbar form{display:none;height:0;overflow:hidden}.navbar .brand{display:none}body.section-servers .navbar .brand,body:not(.has-section) .navbar .brand{display:block;text-align:center;float:none}.navbar .nav-section{position:absolute;background:none}.navbar .nav-section .dropdown-menu{display:none}body.section-servers .navbar .nav-section.servers,body.section-servers .navbar .nav-section.server,body.section-servers .navbar .nav-section.database,body.section-servers .navbar .nav-section.collection,body.section-databases .navbar .nav-section.database,body.section-databases .navbar .nav-section.collection,body.section-collections .navbar .nav-section.servers,body.section-collections .navbar .nav-section.collection,body.section-documents .navbar .nav-section.servers,body.section-documents .navbar .nav-section.server,body.section-document .navbar .nav-section.servers,body.section-document .navbar .nav-section.server{display:none}body.section-databases .navbar .nav-section.servers,body.section-collections .navbar .nav-section.server,body.section-documents .navbar .nav-section.database,body.section-document .navbar .nav-section.database{display:inline-block;float:left;padding:16px 0 0 2px;z-index:1012}body.section-databases .navbar .nav-section.servers > a.dropdown-toggle,body.section-collections .navbar .nav-section.server > a.dropdown-toggle,body.section-documents .navbar .nav-section.database > a.dropdown-toggle,body.section-document .navbar .nav-section.database > a.dropdown-toggle,body.section-databases .navbar .nav-section.servers > a,body.section-collections .navbar .nav-section.server > a,body.section-documents .navbar .nav-section.database > a,body.section-document .navbar .nav-section.database > a{display:inline-block;*display:inline;*zoom:1;padding:4px 12px;margin-bottom:0;font-size:14px;line-height:20px;text-align:center;vertical-align:middle;cursor:pointer;color:#333;text-shadow:0 1px 1px rgba(255,255,255,0.75);background-color:#f5f5f5;background-image:-moz-linear-gradient(top,#fff,#e6e6e6);background-image:-webkit-gradient(linear,0 0,0 100%,from(#fff),to(#e6e6e6));background-image:-webkit-linear-gradient(top,#fff,#e6e6e6);background-image:-o-linear-gradient(top,#fff,#e6e6e6);background-image:linear-gradient(to bottom,#fff,#e6e6e6);background-repeat:repeat-x;filter:progid:DXImageTransform.Microsoft.gradient(startColorstr='#ffffffff',endColorstr='#ffe6e6e6',GradientType=0);border-color:#e6e6e6 #e6e6e6 #bfbfbf;border-color:rgba(0,0,0,0.1) rgba(0,0,0,0.1) rgba(0,0,0,0.25);*background-color:#e6e6e6;filter:progid:DXImageTransform.Microsoft.gradient(enabled = false);border:1px solid#ccc;*border:0;border-bottom-color:#b3b3b3;-webkit-border-radius:4px;-moz-border-radius:4px;border-radius:4px;*margin-left:.3em;-webkit-box-shadow:inset 0 1px 0 rgba(255,255,255,.2),0 1px 2px rgba(0,0,0,.05);-moz-box-shadow:inset 0 1px 0 rgba(255,255,255,.2),0 1px 2px rgba(0,0,0,.05);box-shadow:inset 0 1px 0 rgba(255,255,255,.2),0 1px 2px rgba(0,0,0,.05);-webkit-transition:none;-moz-transition:none;-o-transition:none;transition:none;z-index:10;overflow:visible}body.section-databases .navbar .nav-section.servers > a.dropdown-toggle:hover,body.section-collections .navbar .nav-section.server > a.dropdown-toggle:hover,body.section-documents .navbar .nav-section.database > a.dropdown-toggle:hover,body.section-document .navbar .nav-section.database > a.dropdown-toggle:hover,body.section-databases .navbar .nav-section.servers > a:hover,body.section-collections .navbar .nav-section.server > a:hover,body.section-documents .navbar .nav-section.database > a:hover,body.section-document .navbar .nav-section.database > a:hover,body.section-databases .navbar .nav-section.servers > a.dropdown-toggle:focus,body.section-collections .navbar .nav-section.server > a.dropdown-toggle:focus,body.section-documents .navbar .nav-section.database > a.dropdown-toggle:focus,body.section-document .navbar .nav-section.database > a.dropdown-toggle:focus,body.section-databases .navbar .nav-section.servers > a:focus,body.section-collections .navbar .nav-section.server > a:focus,body.section-documents .navbar .nav-section.database > a:focus,body.section-document .navbar .nav-section.database > a:focus,body.section-databases .navbar .nav-section.servers > a.dropdown-toggle:active,body.section-collections .navbar .nav-section.server > a.dropdown-toggle:active,body.section-documents .navbar .nav-section.database > a.dropdown-toggle:active,body.section-document .navbar .nav-section.database > a.dropdown-toggle:active,body.section-databases .navbar .nav-section.servers > a:active,body.section-collections .navbar .nav-section.server > a:active,body.section-documents .navbar .nav-section.database > a:active,body.section-document .navbar .nav-section.database > a:active,body.section-databases .navbar .nav-section.servers > a.dropdown-toggle.active,body.section-collections .navbar .nav-section.server > a.dropdown-toggle.active,body.section-documents .navbar .nav-section.database > a.dropdown-toggle.active,body.section-document .navbar .nav-section.database > a.dropdown-toggle.active,body.section-databases .navbar .nav-section.servers > a.active,body.section-collections .navbar .nav-section.server > a.active,body.section-documents .navbar .nav-section.database > a.active,body.section-document .navbar .nav-section.database > a.active,body.section-databases .navbar .nav-section.servers > a.dropdown-toggle.disabled,body.section-collections .navbar .nav-section.server > a.dropdown-toggle.disabled,body.section-documents .navbar .nav-section.database > a.dropdown-toggle.disabled,body.section-document .navbar .nav-section.database > a.dropdown-toggle.disabled,body.section-databases .navbar .nav-section.servers > a.disabled,body.section-collections .navbar .nav-section.server > a.disabled,body.section-documents .navbar .nav-section.database > a.disabled,body.section-document .navbar .nav-section.database > a.disabled,body.section-databases .navbar .nav-section.servers > a.dropdown-toggle[disabled],body.section-collections .navbar .nav-section.server > a.dropdown-toggle[disabled],body.section-documents .navbar .nav-section.database > a.dropdown-toggle[disabled],body.section-document .navbar .nav-section.database > a.dropdown-toggle[disabled],body.section-databases .navbar .nav-section.servers > a[disabled],body.section-collections .navbar .nav-section.server > a[disabled],body.section-documents .navbar .nav-section.database > a[disabled],body.section-document .navbar .nav-section.database > a[disabled]{color:#333;background-color:#e6e6e6;*background-color:#d9d9d9}body.section-databases .navbar .nav-section.servers > a.dropdown-toggle:active,body.section-collections .navbar .nav-section.server > a.dropdown-toggle:active,body.section-documents .navbar .nav-section.database > a.dropdown-toggle:active,body.section-document .navbar .nav-section.database > a.dropdown-toggle:active,body.section-databases .navbar .nav-section.servers > a:active,body.section-collections .navbar .nav-section.server > a:active,body.section-documents .navbar .nav-section.database > a:active,body.section-document .navbar .nav-section.database > a:active,body.section-databases .navbar .nav-section.servers > a.dropdown-toggle.active,body.section-collections .navbar .nav-section.server > a.dropdown-toggle.active,body.section-documents .navbar .nav-section.database > a.dropdown-toggle.active,body.section-document .navbar .nav-section.database > a.dropdown-toggle.active,body.section-databases .navbar .nav-section.servers > a.active,body.section-collections .navbar .nav-section.server > a.active,body.section-documents .navbar .nav-section.database > a.active,body.section-document .navbar .nav-section.database > a.active{background-color:#ccc \9}body.section-databases .navbar .nav-section.servers > a.dropdown-toggle:first-child,body.section-collections .navbar .nav-section.server > a.dropdown-toggle:first-child,body.section-documents .navbar .nav-section.database > a.dropdown-toggle:first-child,body.section-document .navbar .nav-section.database > a.dropdown-toggle:first-child,body.section-databases .navbar .nav-section.servers > a:first-child,body.section-collections .navbar .nav-section.server > a:first-child,body.section-documents .navbar .nav-section.database > a:first-child,body.section-document .navbar .nav-section.database > a:first-child{*margin-left:0}body.section-databases .navbar .nav-section.servers > a.dropdown-toggle:hover,body.section-collections .navbar .nav-section.server > a.dropdown-toggle:hover,body.section-documents .navbar .nav-section.database > a.dropdown-toggle:hover,body.section-document .navbar .nav-section.database > a.dropdown-toggle:hover,body.section-databases .navbar .nav-section.servers > a:hover,body.section-collections .navbar .nav-section.server > a:hover,body.section-documents .navbar .nav-section.database > a:hover,body.section-document .navbar .nav-section.database > a:hover,body.section-databases .navbar .nav-section.servers > a.dropdown-toggle:focus,body.section-collections .navbar .nav-section.server > a.dropdown-toggle:focus,body.section-documents .navbar .nav-section.database > a.dropdown-toggle:focus,body.section-document .navbar .nav-section.database > a.dropdown-toggle:focus,body.section-databases .navbar .nav-section.servers > a:focus,body.section-collections .navbar .nav-section.server > a:focus,body.section-documents .navbar .nav-section.database > a:focus,body.section-document .navbar .nav-section.database > a:focus{color:#333;text-decoration:none;background-position:0 -15px;-webkit-transition:background-position .1s linear;-moz-transition:background-position .1s linear;-o-transition:background-position .1s linear;transition:background-position .1s linear}body.section-databases .navbar .nav-section.servers > a.dropdown-toggle:focus,body.section-collections .navbar .nav-section.server > a.dropdown-toggle:focus,body.section-documents .navbar .nav-section.database > a.dropdown-toggle:focus,body.section-document .navbar .nav-section.database > a.dropdown-toggle:focus,body.section-databases .navbar .nav-section.servers > a:focus,body.section-collections .navbar .nav-section.server > a:focus,body.section-documents .navbar .nav-section.database > a:focus,body.section-document .navbar .nav-section.database > a:focus{outline:thin dotted #333;outline:5px auto -webkit-focus-ring-color;outline-offset:-2px}body.section-databases .navbar .nav-section.servers > a.dropdown-toggle.active,body.section-collections .navbar .nav-section.server > a.dropdown-toggle.active,body.section-documents .navbar .nav-section.database > a.dropdown-toggle.active,body.section-document .navbar .nav-section.database > a.dropdown-toggle.active,body.section-databases .navbar .nav-section.servers > a.active,body.section-collections .navbar .nav-section.server > a.active,body.section-documents .navbar .nav-section.database > a.active,body.section-document .navbar .nav-section.database > a.active,body.section-databases .navbar .nav-section.servers > a.dropdown-toggle:active,body.section-collections .navbar .nav-section.server > a.dropdown-toggle:active,body.section-documents .navbar .nav-section.database > a.dropdown-toggle:active,body.section-document .navbar .nav-section.database > a.dropdown-toggle:active,body.section-databases .navbar .nav-section.servers > a:active,body.section-collections .navbar .nav-section.server > a:active,body.section-documents .navbar .nav-section.database > a:active,body.section-document .navbar .nav-section.database > a:active{background-image:none;outline:0;-webkit-box-shadow:inset 0 2px 4px rgba(0,0,0,.15),0 1px 2px rgba(0,0,0,.05);-moz-box-shadow:inset 0 2px 4px rgba(0,0,0,.15),0 1px 2px rgba(0,0,0,.05);box-shadow:inset 0 2px 4px rgba(0,0,0,.15),0 1px 2px rgba(0,0,0,.05)}body.section-databases .navbar .nav-section.servers > a.dropdown-toggle.disabled,body.section-collections .navbar .nav-section.server > a.dropdown-toggle.disabled,body.section-documents .navbar .nav-section.database > a.dropdown-toggle.disabled,body.section-document .navbar .nav-section.database > a.dropdown-toggle.disabled,body.section-databases .navbar .nav-section.servers > a.disabled,body.section-collections .navbar .nav-section.server > a.disabled,body.section-documents .navbar .nav-section.database > a.disabled,body.section-document .navbar .nav-section.database > a.disabled,body.section-databases .navbar .nav-section.servers > a.dropdown-toggle[disabled],body.section-collections .navbar .nav-section.server > a.dropdown-toggle[disabled],body.section-documents .navbar .nav-section.database > a.dropdown-toggle[disabled],body.section-document .navbar .nav-section.database > a.dropdown-toggle[disabled],body.section-databases .navbar .nav-section.servers > a[disabled],body.section-collections .navbar .nav-section.server > a[disabled],body.section-documents .navbar .nav-section.database > a[disabled],body.section-document .navbar .nav-section.database > a[disabled]{cursor:default;background-image:none;opacity:.65;filter:alpha(opacity=65);-webkit-box-shadow:none;-moz-box-shadow:none;box-shadow:none}body.section-databases .navbar .nav-section.servers > a.dropdown-toggle .label,body.section-collections .navbar .nav-section.server > a.dropdown-toggle .label,body.section-documents .navbar .nav-section.database > a.dropdown-toggle .label,body.section-document .navbar .nav-section.database > a.dropdown-toggle .label,body.section-databases .navbar .nav-section.servers > a .label,body.section-collections .navbar .nav-section.server > a .label,body.section-documents .navbar .nav-section.database > a .label,body.section-document .navbar .nav-section.database > a .label,body.section-databases .navbar .nav-section.servers > a.dropdown-toggle .badge,body.section-collections .navbar .nav-section.server > a.dropdown-toggle .badge,body.section-documents .navbar .nav-section.database > a.dropdown-toggle .badge,body.section-document .navbar .nav-section.database > a.dropdown-toggle .badge,body.section-databases .navbar .nav-section.servers > a .badge,body.section-collections .navbar .nav-section.server > a .badge,body.section-documents .navbar .nav-section.database > a .badge,body.section-document .navbar .nav-section.database > a .badge{position:relative;top:-1px}html.cssmask body.section-databases .navbar .nav-section.servers > a.dropdown-toggle,html.cssmask body.section-collections .navbar .nav-section.server > a.dropdown-toggle,html.cssmask body.section-documents .navbar .nav-section.database > a.dropdown-toggle,html.cssmask body.section-document .navbar .nav-section.database > a.dropdown-toggle,html.cssmask body.section-databases .navbar .nav-section.servers > a,html.cssmask body.section-collections .navbar .nav-section.server > a,html.cssmask body.section-documents .navbar .nav-section.database > a,html.cssmask body.section-document .navbar .nav-section.database > a{display:inline-block;position:relative;padding-left:8px;-webkit-transition:none;-moz-transition:none;-o-transition:none;transition:none}html.cssmask body.section-databases .navbar .nav-section.servers > a.dropdown-toggle:before,html.cssmask body.section-collections .navbar .nav-section.server > a.dropdown-toggle:before,html.cssmask body.section-documents .navbar .nav-section.database > a.dropdown-toggle:before,html.cssmask body.section-document .navbar .nav-section.database > a.dropdown-toggle:before,html.cssmask body.section-databases .navbar .nav-section.servers > a:before,html.cssmask body.section-collections .navbar .nav-section.server > a:before,html.cssmask body.section-documents .navbar .nav-section.database > a:before,html.cssmask body.section-document .navbar .nav-section.database > a:before{position:absolute;left:-9px;top:2px;height:23px;width:23px;content:" ";background-color:#fff;background-image:-webkit-gradient(linear,top left,bottom right,from(#fff),to(#e6e6e6));background-image:-webkit-linear-gradient(-45deg,#fff,#e6e6e6);background-image:-moz-linear-gradient(-45deg,#fff,#e6e6e6);background-image:-o-linear-gradient(-45deg,#fff,#e6e6e6);background-image:linear-gradient(-45deg,#fff,#e6e6e6);background-repeat:repeat-x;border-left:1px solid #d9d9d9;border-bottom:1px solid #bfbfbf;-webkit-border-radius:7px 0 7px 0;-moz-border-radius:7px 0 7px 0;border-radius:7px 0 7px 0;display:inline-block;-webkit-transform:rotate(45deg) skew(3deg,3deg);-moz-transform:rotate(45deg) skew(3deg,3deg);-ms-transform:rotate(45deg) skewX(3deg) skewY(3deg);-o-transform:rotate(45deg) skew(3deg,3deg);transform:rotate(45deg) skew(3deg,3deg);-webkit-box-shadow:inset 1px 0 0 rgba(255,255,255,0.2);-moz-box-shadow:inset 1px 0 0 rgba(255,255,255,0.2);box-shadow:inset 1px 0 0 rgba(255,255,255,0.2);-webkit-mask-image:-webkit-gradient(linear,left bottom,right top,from(#000),color-stop(0.5,#000),color-stop(0.5,transparent),to(transparent));-webkit-mask-image:-webkit-linear-gradient(45deg,#000,#000 25%,#000 50%,transparent 50%,transparent);-moz-mask-image:-moz-linear-gradient(45deg,#000,#000 25%,#000 50%,transparent 50%,transparent);-o-mask-image:-o-linear-gradient(45deg,#000,#000 25%,#000 50%,transparent 50%,transparent);mask-image:linear-gradient(45deg,#000,#000 25%,#000 50%,transparent 50%,transparent);-webkit-background-clip:content;-moz-background-clip:content;background-clip:content}html.cssmask body.section-databases .navbar .nav-section.servers > a.dropdown-toggle:hover:before,html.cssmask body.section-collections .navbar .nav-section.server > a.dropdown-toggle:hover:before,html.cssmask body.section-documents .navbar .nav-section.database > a.dropdown-toggle:hover:before,html.cssmask body.section-document .navbar .nav-section.database > a.dropdown-toggle:hover:before,html.cssmask body.section-databases .navbar .nav-section.servers > a:hover:before,html.cssmask body.section-collections .navbar .nav-section.server > a:hover:before,html.cssmask body.section-documents .navbar .nav-section.database > a:hover:before,html.cssmask body.section-document .navbar .nav-section.database > a:hover:before{background-color:#e8e8e8;background-position:-10px -10px}html.cssmask body.section-databases .navbar .nav-section.servers > a.dropdown-toggle:active:before,html.cssmask body.section-collections .navbar .nav-section.server > a.dropdown-toggle:active:before,html.cssmask body.section-documents .navbar .nav-section.database > a.dropdown-toggle:active:before,html.cssmask body.section-document .navbar .nav-section.database > a.dropdown-toggle:active:before,html.cssmask body.section-databases .navbar .nav-section.servers > a:active:before,html.cssmask body.section-collections .navbar .nav-section.server > a:active:before,html.cssmask body.section-documents .navbar .nav-section.database > a:active:before,html.cssmask body.section-document .navbar .nav-section.database > a:active:before{background-color:#e6e6e6;background-color:#d9d9d9 \9;background-image:none;-webkit-box-shadow:inset 0 3px 4px rgba(0,0,0,0.15);-moz-box-shadow:inset 0 3px 4px rgba(0,0,0,0.15);box-shadow:inset 0 3px 4px rgba(0,0,0,0.15)}body.section-databases .navbar .nav-section.servers.dropdown .dropdown-toggle,body.section-collections .navbar .nav-section.server.dropdown .dropdown-toggle,body.section-documents .navbar .nav-section.database.dropdown .dropdown-toggle,body.section-document .navbar .nav-section.database.dropdown .dropdown-toggle{padding:4px 14px}body.section-databases .navbar .nav-section.server,body.section-collections .navbar .nav-section.database,body.section-documents .navbar .nav-section.collection,body.section-document .navbar .nav-section.collection{width:12em;left:50%;margin-left:-6em;padding-top:20px;display:inline-block;float:none;text-align:center;z-index:1011}body.section-databases .navbar .nav-section.server > a,body.section-collections .navbar .nav-section.database > a,body.section-documents .navbar .nav-section.collection > a,body.section-document .navbar .nav-section.collection > a{font-family:"Rokkitt",serif;font-size:24px;line-height:24px}body.section-databases .navbar .nav-section.server .dropdown-toggle,body.section-collections .navbar .nav-section.database .dropdown-toggle,body.section-documents .navbar .nav-section.collection .dropdown-toggle,body.section-document .navbar .nav-section.collection .dropdown-toggle{padding:0}.masthead{text-align:center}.masthead .container{padding:0 20px}.masthead.epic h1{font-size:60px}.masthead.epic h2{font-size:40px}.masthead.epic p{font-size:20px}.app-section{border:none;-webkit-border-radius:0;-moz-border-radius:0;border-radius:0}table,thead,tbody,th,td,tr{display:block}table{border:none}table thead tr{position:absolute;top:-9999px;left:-9999px}table tr{border:1px solid #DDD;border-bottom:none}table tr:last-child{border-bottom:1px solid #DDD}table tr:first-child,table tr:first-child > td:first-child{-webkit-border-top-left-radius:5px;-moz-border-radius-topleft:5px;border-top-left-radius:5px;-webkit-border-top-right-radius:5px;-moz-border-radius-topright:5px;border-top-right-radius:5px}table tr:last-child,table tr:last-child > td:last-child{-webkit-border-bottom-left-radius:5px;-moz-border-radius-bottomleft:5px;border-bottom-left-radius:5px;-webkit-border-bottom-right-radius:5px;-moz-border-radius-bottomright:5px;border-bottom-right-radius:5px}table td{border:none;position:relative;padding-left:35%}table td:before{position:absolute;top:6px;left:6px;width:30%;padding-right:10px;white-space:nowrap;font-weight:700}#keyboard-shortcuts{width:360px;margin-left:-180px}#servers table td:nth-of-type(1):before{content:"name"}#servers table td:nth-of-type(2):before{content:"databases"}#servers table td:nth-of-type(3):before{content:"size"}#servers table td:nth-of-type(4),#servers table td.action-column{display:none}#databases table td:nth-of-type(1):before{content:"name"}#databases table td:nth-of-type(2):before{content:"collections"}#databases table td:nth-of-type(3):before{content:"size"}#databases table td:nth-of-type(4),#databases table td.action-column{display:none}#collections table td:nth-of-type(1):before{content:"name"}#collections table td:nth-of-type(2):before{content:"documents"}#collections table td:nth-of-type(3):before{content:"indexes"}#collections table td:nth-of-type(4),#collections table td.action-column{display:none}}

@@ script.js
/**
 * Genghis v2.3.6
 *
 * The single-file MongoDB admin app
 *
 * http://genghisapp.com
 *
 * @author Justin Hileman <justin@justinhileman.info>
 */


