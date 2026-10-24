# frozen_string_literal: true

require_relative "lib/picoride/version"

Gem::Specification.new do |spec|
  spec.name = "picoride"
  spec.version = Picoride::VERSION
  spec.authors = ["youchan"]
  spec.email = ["youchan@gmail.com"]

  spec.summary = "PicoRuby ESP32 IDE"
  spec.description = "A Integrated develop emvironment for PicoRuby ESP32"
  spec.homepage = "https://github.com/youchan/picoride"
  spec.license = "MIT"
  spec.required_ruby_version = ">= 3.2.0"

  spec.metadata["allowed_push_host"] = "https://rubygems.org"
  spec.metadata["homepage_uri"] = spec.homepage
  spec.metadata["source_code_uri"] = "https://github.com/youchan/picoride"
  spec.metadata["changelog_uri"] = "https://github.com/youchan/picoride/CHANGELOG.md"

  # Specify which files should be added to the gem when it is released.
  # The `git ls-files -z` loads the files in the RubyGem that have been added into git.
  gemspec = File.basename(__FILE__)
  spec.files = IO.popen(%w[git ls-files -z], chdir: __dir__, err: IO::NULL) do |ls|
    ls.readlines("\x0", chomp: true).reject do |f|
      (f == gemspec) ||
        f.start_with?(*%w[bin/ Gemfile .gitignore test/ .github/ rakelib/])
    end
  end
  spec.bindir = "exe"
  spec.executables = spec.files.grep(%r{\Aexe/}) { |f| File.basename(f) }
  spec.require_paths = ["lib"]

  spec.add_dependency "sinatra"
  spec.add_dependency "puma"
  spec.add_dependency "rackup"
  spec.add_dependency "perfect_toml"

  # For more information and examples about making a new gem, check out our
  # guide at: https://bundler.io/guides/creating_gem.html
end
