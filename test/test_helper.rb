# frozen_string_literal: true

require "devbox"

require "fileutils"
require "tmpdir"

require "minitest/autorun"
require "minitest/hooks/default"

class Minitest::Test
  include Minitest::Hooks
end
