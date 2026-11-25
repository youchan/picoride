module PicoRIDE
  class BuildStatus
    def initialize
      @state = :init
      @platform_building = false
    end

    def platform_setup_started
      @platform_building = true
    end
  end
end
