# frozen_string_literal: true

require_relative "picoruby_esp32_ide/version"

module PicorubyEsp32Ide
  class Error < StandardError; end
end

require_relative "picoruby_esp32_ide/background_job"
require_relative "picoruby_esp32_ide/r2p2_state"
