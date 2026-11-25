module PicoRIDE
  class Project
    attr_reader :path

    def initialize(path)
      @path = path
    end
  end
end
