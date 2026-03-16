# frozen_string_literal: true

require 'legion/extensions/apollo/version'

module Legion
  module Extensions
    module Apollo
      extend Legion::Extensions::Core if Legion::Extensions.const_defined? :Core
    end
  end
end
