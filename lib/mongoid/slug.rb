require 'mongoid'
require 'stringex'
require 'mongoid/slug/criteria'
require 'mongoid/slug/index'
require 'mongoid/slug/unique_slug'
require 'mongoid/slug/slug_id_strategy'
require 'mongoid-compatibility'
require 'mongoid/slug/railtie' if defined?(Rails)

module Mongoid
  # Slugs your Mongoid model.
  module Slug
    extend ActiveSupport::Concern

    MONGO_INDEX_KEY_LIMIT_BYTES = 1024

    included do
      cattr_accessor :slug_reserved_words,
                     :slug_scope,
                     :slugged_attributes,
                     :slug_url_builder,
                     :slug_history,
                     :slug_by_model_type,
                     :slug_max_length
    end

    class << self
      attr_accessor :default_slug
      def configure(&block)
        instance_eval(&block)
      end

      def slug_method(&block)
        @default_slug = block if block_given?
      end
    end

    module ClassMethods
      # @overload slug(*fields)
      #   Sets one ore more fields as source of slug.
      #   @param [Array] fields One or more fields the slug should be based on.
      #   @yield If given, the block is used to build a custom slug.
      #
      # @overload slug(*fields, options)
      #   Sets one ore more fields as source of slug.
      #   @param [Array] fields One or more fields the slug should be based on.
      #   @param [Hash] options
      #   @param options [Boolean] :history Whether a history of changes to
      #   the slug should be retained. When searched by slug, the document now
      #   matches both past and present slugs.
      #   @param options [Boolean] :permanent Whether the slug should be
      #   immutable. Defaults to `false`.
      #   @param options [Array] :reserve` A list of reserved slugs
      #   @param options :scope [Symbol] a reference association or field to
      #   scope the slug by. Embedded documents are, by default, scoped by
      #   their parent.
      #   @param options :max_length [Integer] the maximum length of the text portion of the slug
      #   @yield If given, a block is used to build a slug.
      #
      # @example A custom builder
      #   class Person
      #     include Mongoid::Document
      #     include Mongoid::Slug
      #
      #     field :names, :type => Array
      #     slug :names do |doc|
      #       doc.names.join(' ')
      #     end
      #   end
      #
      def slug_method(*fields, &block)
        options = fields.extract_options!

        self.slug_scope            = options[:scope]
        self.slug_reserved_words   = options[:reserve] || Set.new(%w[new edit])
        self.slugged_attributes    = fields.map(&:to_s)
        self.slug_history          = options[:history]
        self.slug_by_model_type    = options[:by_model_type]
        self.slug_max_length       = options.key?(:max_length) ? options[:max_length] : MONGO_INDEX_KEY_LIMIT_BYTES - 32

        field :slug
        # alias_attribute :slug, :_slug
        field :slug_lower

        # Set index
        # index(*Mongoid::Slug::Index.build_index(slug_scope_key, slug_by_model_type)) unless embedded?

        self.slug_url_builder = block_given? ? block : default_slug_url_builder

        #-- always create slug on create
        #-- do not create new slug on update if the slug is permanent
        if options[:permanent]
          set_callback :create, :before, :build_slug
        else
          set_callback :save, :before, :build_slug, if: :slug_should_be_rebuilt?
        end
      end

      def default_slug_url_builder
        Mongoid::Slug.default_slug || ->(cur_object) { cur_object.slug_builder.to_url }
      end

      def look_like_slugs?(*args)
        with_default_scope.look_like_slugs?(*args)
      end

      # Returns the scope key for indexing, considering associations
      #
      # @return [ Array<Document>, Document ]
      def slug_scope_key
        return nil unless slug_scope
        reflect_on_association(slug_scope).try(:key) || slug_scope
      end

      # Find documents by slugs.
      #
      # A document matches if any of its slugs match one of the supplied params.
      #
      # A document matching multiple supplied params will be returned only once.
      #
      # If any supplied param does not match a document a Mongoid::Errors::DocumentNotFound will be raised.
      #
      # @example Find by a slug.
      #   Model.find_by_slug!('some-slug')
      #
      # @example Find by multiple slugs.
      #   Model.find_by_slug!('some-slug', 'some-other-slug')
      #
      # @param [ Array<Object> ] args The slugs to search for.
      #
      # @return [ Array<Document>, Document ] The matching document(s).
      def find_by_slug!(*args)
        with_default_scope.find_by_slug!(*args)
      end

      def queryable
        current_scope || Criteria.new(self) # Use Mongoid::Slug::Criteria for slugged documents.
      end

      private

      if Mongoid::Compatibility::Version.mongoid5_or_newer? && Threaded.method(:current_scope).arity == -1
        def current_scope
          Threaded.current_scope(self)
        end
      elsif Mongoid::Compatibility::Version.mongoid5_or_newer?
        def current_scope
          Threaded.current_scope
        end
      else
        def current_scope
          scope_stack.last
        end
      end
    end

    # Builds a new slug.
    #
    # @return [true]
    def build_slug
      apply_slug
      true
    end

    def apply_slug
      new_slug = find_unique_slug
      return true if new_slug.size.zero?

      self.slug_lower = new_slug.downcase
      self.slug = new_slug
    end

    # Builds slug then atomically sets it in the database.
    def set_slug!
      build_slug
      set(slug: slug)
    end

    # Atomically unsets the slug field in the database. It is important to unset
    # the field for the sparse index on slugs.
    #
    # This also resets the in-memory value of the slug field to its default (empty array)
    def unset_slug!
      unset(:slug)
      clear_slug!
    end

    # Rolls back the slug value from the Mongoid changeset.
    def reset_slug!
      reset_slugs!
    end

    # Sets the slug to its default value.
    def clear_slug!
      self.slug = nil
    end

    # Finds a unique slug, were specified string used to generate a slug.
    #
    # Returned slug will the same as the specified string when there are no
    # duplicates.
    #
    # @return [String] A unique slug
    def find_unique_slug
      UniqueSlug.new(self).find_unique
    end

    # @return [Boolean] Whether the slug requires to be rebuilt
    def slug_should_be_rebuilt?
      new_record? || slug_changed? || slugged_attributes_changed?
    end

    def slugged_attributes_changed?
      slugged_attributes.any? { |f| attribute_changed? f.to_s }
    end

    # @return [String] A string which Action Pack uses for constructing an URL
    # to this record.
    def to_param
      slug || super
    end

    def slug_builder
      cur_slug = nil
      if new_with_slugs? || persisted_with_slug_changes?
        # user defined slug
        cur_slug = slug
      end
      # generate slug if the slug is not user defined or does not exist
      cur_slug || pre_slug_string
    end

    private

    # Returns true if object is a new record and slugs are present
    def new_with_slugs?
      new_record? && slug.present?
    end

    # Returns true if object has been persisted and has changes in the slug
    def persisted_with_slug_changes?
      persisted? && slug_changed?
    end

    def pre_slug_string
      slugged_attributes.map { |f| send f }.join ' '
    end
  end
end
