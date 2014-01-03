require 'oauth2'
require 'json'
require 'rest-client'

# AasSdk provides a thin wrapper around the AAS API. See API docs at http://aas.yesvideo.com for details on resource attributes and endpoint
# parameters.
#
# Basic usage:
#
# @example Setup API credentials:
#
#   AasSdk.setup(ENV['AAS_CLIENT_ID'], ENV['AAS_SECRET'])
#
# @example Create a new collection
#
#   collection = AasSdk::Collection.create
#
# @example Upload a local file
#
#   collection.upload_file('/path/to/burn/to/disc', 'path/to/local/file')
#
# @example Mark the collection as complete
#
#   collection.set_complete
#
# @example Create an order to burn the collection to disc & ship
#
#   ship_to = AasSdk::Order::ShipTo.new(
#     recipient: 'John Smith',
#     address1: '1 Main St.',
#     city: 'San Francisco',
#     state: 'CA',
#     postal_code: '94111',
#     phone_number: '(415) 555 1212'
#   )
# 
#   order = AasSdk::Order.create(collection.id, 'My DVD from the Cloud', ship_to)
#
# @example Check order status
#
#   AasSdk::Order.find(order.id).status
#
class AasSdk
  MAX_CHUNK_BYTES = [(ENV['AAS_MAX_CHUNK_BYTES'] || 1024**3).to_i, 1024].max # 1GB default, 1K min
  private_constant :MAX_CHUNK_BYTES

  # Base class with various helper methods.
  class Common
    # Instantiate based on a hash of attributes.
    #
    # @param attrs [Hash]
    def initialize(attrs = {})
      set_attributes(attrs)
    end

    # Sets attributes from a hash using setters.
    # @private
    def set_attributes(attrs)
      attrs.each do |k, v|
        send("#{k}=".to_sym, v)
      end
      self
    end

    # Helper method for defining Timestamp setters that accept either Dates or Strings.
    #
    # @param params [Array<Symbol>] list of timestamp attributes
    # @private
    def self.timestamp(*params)
      params.each do |param|
        define_method("#{param}=") do |s|
          instance_variable_set("@#{param}", s.is_a?(Date) ? s : DateTime.parse(s))
        end
      end
    end
  end

  # UploadCfg encapsulates the results of a file or file part upload_cfg get request and supports
  # using that configuration for uploading either a file or a byte string.
  class UploadCfg < Common
    attr_accessor :url, :data, :callback_url

    # Uploads a local file.
    # 
    # @param local_filename [String] the path of the local file to upload
    # @return [File] The uploaded file.
    def upload_file(local_filename)
      resp = RestClient.post(url, data.merge({file: ::File.new(local_filename, 'rb')}))
      File.new(JSON.parse(resp.body))
    end

    # Uploads a byte string as a new FilePart.
    # 
    # @param str [String] the data to upload.
    # @return [FilePart] The uploaded file part.
    def upload_bytes(str)
      # RestClient treats io-like objects that respond to :path as a file attachment
      strio = StringIO.new(str)
      def strio.path; 'chunk'; end

      resp = RestClient.post(url, data.merge({file: strio}))
      FilePart.new(JSON.parse(resp.body))
    end
  end
  private_constant :UploadCfg
  
  # Represents a Collection of files to be burned to disc.
  class Collection < Common
    class << self
      # Lists collections.
      #
      # @return [Array<Collection>]
      def index
        AasSdk.get('collections')['collections'].map{|attrs| new(attrs)}
      end

      # Creates a collection.
      #
      # @param type ['dvd_4_7G', 'blueray_25G'] Type of collection to create.
      # @return [Collection]
      def create(type = 'dvd_4_7G')
        new(AasSdk.post('collections', {type: type}))
      end

      # Finds a collection
      #
      # @param id [String] ID of the collection to return.
      # @return [Collection]
      def find(id)
        new(AasSdk.get("collections/#{id}"))
      end
    end

    # @!attribute id
    #   @return [String] the Collection ID.
    # @!attribute created_at
    #   @return [Timestamp] the creation time.
    # @!attribute expires_at
    #   @return [Timestamp] the expiration time (after which no new orders may be created from this collection).
    # @!attribute expires_at
    #   @return [Timestamp] the expiration time (after which no new orders may be created from this collection).
    # @!attribute bytes
    #   @return [Integer] the bytes used by files in the collection.
    # @!attribute bytes_left
    #   @return [Integer] the byte capacity remaining.
    # @!attribute type
    #   @return ['dvd_4_7G', 'blueray_25G'] the collection type
    # @!attribute upload_status
    #   @return ['ready', 'complete', 'expired'] the collection upload status
    attr_accessor :id, :created_at, :expires_at, :type, :upload_status, :bytes, :bytes_left
    timestamp :created_at, :expires_at

    # Sets the collection status to complete (and ready for burning).
    #
    # @return [nil]
    def set_complete
      set_attributes(AasSdk.put(resource_path, {upload_status: 'complete'}))
      nil
    end

    # Returns the files in this collection.
    #
    # @return [Array<File>]
    def files
      AasSdk.get("#{resource_path}/files")['files'].map{|attrs| File.new(attrs)}
    end

    # Finds a file in this collection.
    #
    # @param file_id [String] ID of the file to return.
    # @return [File]
    def find_file(file_id)
      File.find(id, file_id)
    end

    # Deletes this collection.
    #
    # @return [nil]
    def destroy
      AasSdk.delete(resource_path)
      nil
    end

    # Uploads a local file to the collection.
    #
    # @param path [String] Path that will be used when burning the file to disc.
    # @param local_filename [String] The path of the local file to upload.
    # @return [File] The uploaded file.
    def upload_file(path, local_filename)
      if ::File.size(local_filename) < MAX_CHUNK_BYTES
        get_upload_cfg(path).upload_file(local_filename)
      else
        file = create_file_for_chunked_upload(path)
        ::File.open(local_filename, 'rb') do |f|
          i = 0
          while chunk = f.read(MAX_CHUNK_BYTES)
            file.upload_chunk(i, chunk)
            i += 1
          end
        end
        file.set_complete
        file
      end
    end

    # Creates a file for use with chunked uploads.
    #
    # @param path [String] Path that will be used when burning the file to disc.
    # @return [File] The created file.
    def create_file_for_chunked_upload(path)
      File.new(AasSdk.post("#{resource_path}/files", {path: path}))
    end

  private
    def resource_path
      "collections/#{id}"
    end

    def get_upload_cfg(path)
      UploadCfg.new(AasSdk.get("#{resource_path}/files/upload_cfg", {params: {path: path}}))
    end
  end

  # Represents a File in a Collection.
  class File < Common
    class << self
      # Finds a File
      #
      # @param collection_id [String] ID of the collection that contains the file.
      # @param id [String] ID of the file to return.
      # @return [File]
      def find(collection_id, id)
        new(AasSdk.get("collections/#{collection_id}/files/#{id}"))
      end
    end
    
    # @!attribute id
    #   @return [String] the File ID.
    # @!attribute collection_id
    #   @return [String] the ID of the collection that contains this file.
    # @!attribute path
    #   @return [String] The path that will be used when burning this file to disc.
    # @!attribute chunked_status
    #   @return ['none', 'ready', 'complete', 'merged'] The chunked upload status.
    # @!attribute bytes
    #   @return [Integer] the byte size of this file (or of its constituent parts, once marked complete).
    attr_accessor :id, :collection_id, :path, :chunked_status, :bytes

    # Sets the chunked upload status to complete.
    #
    # @return [nil]
    def set_complete
      set_attributes(AasSdk.put(resource_path, {chunked_status: 'complete'}))
      nil
    end

    # Returns the file parts that make up this file (if any).
    #
    # @return [Array<FilePart>]
    def parts
      AasSdk.get("#{resource_path}/parts")['parts'].map{|attrs| FilePart.new(attrs)}
    end

    # Finds a file part that is part of this file.
    #
    # @param part_id [String] ID of the file part to return.
    # @return [FilePart]
    def find_part(part_id)
      FilePart.find(collection_id, id, part_id)
    end

    # Deletes this file.
    #
    # @return [nil]
    def destroy
      AasSdk.delete(resource_path)
      nil
    end

    # Uploads a local file as a part of this file.
    #
    # @param seq_id [Integer] The 0-based sequence id of the part to upload.
    # @param chunk [String] The bytes to upload.
    # @return [FilePart] The uploaded file part.
    def upload_chunk(seq_id, chunk)
      get_upload_cfg(seq_id).upload_bytes(chunk)
    end

  private
    def resource_path
      "collections/#{collection_id}/files/#{id}"
    end

    def get_upload_cfg(seq_id)
      UploadCfg.new(AasSdk.get("#{resource_path}/parts/upload_cfg", {params: {seq_id: seq_id}}))
    end
  end

  # Represents a part of chunked file.
  class FilePart < Common
    class << self
      # Finds a FilePart.
      #
      # @param collection_id [String] ID of the collection that contains the file.
      # @param file_id [String] ID of the file that contains the file part.
      # @param id [String] ID of the file part to return.
      # @return [FilePart]
      def find(collection_id, file_id, id)
        new(AasSdk.get("collections/#{collection_id}/files/#{file_id}/parts/#{id}"))
      end
    end
    
    # @!attribute id
    #   @return [String] the FilePart ID.
    # @!attribute collection_id
    #   @return [String] the ID of the collection that contains the file that contains this file part.
    # @!attribute file_id
    #   @return [String] the ID of the file that contains this file part.
    # @!attribute seq_id
    #   @return [Integer] The 0-based sequence id of this file part.
    # @!attribute bytes
    #   @return [Integer] the byte size of this file part.
    attr_accessor :id, :collection_id, :file_id, :seq_id, :bytes
  end

  # Represents a disc order.
  class Order < Common
    # Represents a shipping address for an order
    class ShipTo < Common
      # @!attribute recipient
      #   @return [String] 
      # @!attribute address1
      #   @return [String] 
      # @!attribute address2
      #   @return [String] 
      # @!attribute city
      #   @return [String] 
      # @!attribute state
      #   @return [String] 
      # @!attribute postal_code
      #   @return [String] 
      # @!attribute phone_number
      #   @return [String] 
      attr_accessor :recipient, :address1, :address2, :city, :state, :postal_code, :phone_number

      # @private
      def to_h
        {
          recipient: recipient,
          address1: address1,
          address2: address2,
          city: city,
          state: state,
          postal_code: postal_code,
          phone_number: phone_number
        }
      end
      
      # @private
      def to_s
        "#{recipient} / #{address1} / #{address2} / #{city}, #{state} #{postal_code} / #{phone_number}"
      end
    end

    class << self
      # Lists orders.
      #
      # @return [Array<Order>]
      def index
        AasSdk.get('orders')['orders'].map{|attrs| new(attrs)}
      end

      # Creates an order for burning and shipping a collection to disc.
      #
      # @param collection_id [String] ID of the collection to burn.
      # @param title [String] Title of the disc.
      # @param ship_to [ShipTo] Shipping address.
      # @param no_disc [boolean] Optionally disables disc burning & shipping (just creates an order object).
      # @return [Order]
      def create(collection_id, title, ship_to, no_disc = false)
        new(AasSdk.post('orders', {collection_id: collection_id, title: title, ship_to: ship_to.to_h, no_disc: no_disc}))
      end

      # Finds an order.
      #
      # @param id [String] ID of the order to return.
      # @return [Order]
      def find(id)
        new(AasSdk.get("orders/#{id}"))
      end
    end

    # @!attribute id
    #   @return [String] the Order ID.
    # @!attribute created_at
    #   @return [Timestamp] the creation time.
    # @!attribute updated_at
    #   @return [Timestamp] the last update time.
    # @!attribute collection_id
    #   @return [String] ID of the collection that this is an order for.
    # @!attribute title
    #   @return [String] The title of the disc to burn.
    # @!attribute status
    #   @return ['received', 'burning', 'shipped', 'test_complete'] The current order status.
    # @!attribute ship_to
    #   @return [ShipTo] The shipping information.
    # @!attribute total
    #   @return [String] The order price.
    attr_accessor :id, :created_at, :updated_at, :collection_id, :title, :status, :ship_to, :total
    timestamp :created_at, :updated_at

    # Sets ship_to from either a ShipTo instance of from a Hash of ShipTo attributes.
    #
    # @param ship_to_or_attrs [ShipTo, Hash]
    def ship_to=(ship_to_or_attrs)
      @ship_to = 
        if ship_to_or_attrs.is_a? ShipTo
          ship_to_or_attrs
        else
          ShipTo.new(ship_to_or_attrs)
        end
    end
  end

  class << self
    # Initializes the SDK.
    #
    # @param client_id [String] The API credentials client_id
    # @param secret [String] The API credentials secret
    def setup(client_id, secret, api_url = 'https://aas.yesvideo.com/')
      @cli = OAuth2::Client.new(client_id, secret, site: api_url)
      @tok = nil
      @base_path = "/api/v1/"
      true
    end

    # Returns the oauth client
    #
    # @private
    def client
      @cli || raise('Call setup first')
    end

    # Refreshes and returns the oauth access token
    #
    # @private
    def refresh_access_token
      @tok = client.client_credentials.get_token
    end

    # Returns the oauth access token
    #
    # @private
    def access_token
      @tok || refresh_access_token
    end

    # Passes the current access token to the given block.  If the block throws an invliad_token oauth error,
    # then refreshes the access token and passes it again to the given block.  Effectively, this provides
    # automatic token refresh when interacting with the API.
    #
    # @yield [OAuth2::AccessToken]
    # @private
    def with_access_token
      begin
        yield access_token
      rescue OAuth2::Error => e
        if e.code == 'invalid_token'
          refresh_access_token
          yield access_token
        else
          raise e
        end
      end
    end

    # Performs a get request using the oauth access token.
    #
    # @private
    def get(path, opts = {})
      with_access_token do |access_token|
        resp = access_token.get("#{@base_path}#{path}", opts)
        body = JSON.parse(resp.body)
        raise body['error'] if body['error']
        body
      end
    end

    # Performs a put request using the oauth access token.
    #
    # @private
    def put(path, attrs)
      with_access_token do |access_token|
        resp = access_token.put("#{@base_path}#{path}", body: attrs)
        body = JSON.parse(resp.body)
        raise body['error'] if body['error']
        body
      end
    end

    # Performs a post request using the oauth access token.
    #
    # @private
    def post(path, attrs)
      with_access_token do |access_token|
        resp = access_token.post("#{@base_path}#{path}", body: attrs)
        body = JSON.parse(resp.body)
        raise body['error'] if body['error']
        body
      end
    end

    # Performs a delete request using the oauth access token.
    #
    # @private
    def delete(path)
      with_access_token do |access_token|
        access_token.delete("#{@base_path}#{path}")
      end
    end
  end
end