# -*- encoding: utf-8 -*-
lib = File.expand_path("../lib", __FILE__)
$LOAD_PATH.unshift(lib) unless $LOAD_PATH.include?(lib)
require "rscons/version"

Gem::Specification.new do |gem|
  gem.name          = "rscons"
  gem.version       = Rscons::VERSION
  gem.authors       = ["Josh Holtrop"]
  gem.email         = ["jholtrop@gmail.com"]
  gem.description   = %q{Software construction library inspired by SCons and implemented in Ruby.}
  gem.summary       = %q{Software construction library inspired by SCons and implemented in Ruby}
  gem.homepage      = "https://github.com/holtrop/rscons"
  gem.license       = "MIT"

  gem.files         = Dir["{bin,assets,lib}/**/*", "*.gemspec", "LICENSE.txt"]
  gem.executables   = gem.files.grep(%r{^bin/}).map{ |f| File.basename(f) }
  gem.test_files    = gem.files.grep(%r{^(test|spec|features)/})
  gem.require_paths = ["lib"]

  gem.add_dependency "json", ">= 1.8", "< 3.0"
  gem.add_dependency "e2mmap", ">= 0.1.0"
  gem.add_dependency "thwait", ">= 0.1.0"

  gem.add_development_dependency "rspec"
  gem.add_development_dependency "rake"
  gem.add_development_dependency "simplecov"
  gem.add_development_dependency "yard"
  gem.add_development_dependency "rdoc"
end
