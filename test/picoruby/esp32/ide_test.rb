# frozen_string_literal: true

require "test_helper"

class Picoruby::Esp32::IdeTest < Test::Unit::TestCase
  test "VERSION" do
    assert do
      ::Picoruby::Esp32::Ide.const_defined?(:VERSION)
    end
  end

  test "something useful" do
    assert_equal("expected", "actual")
  end
end
