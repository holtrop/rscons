#!/usr/bin/env ruby

require "base64"
require "digest/md5"
require "fileutils"
require "stringio"
require "zlib"

if File.read("lib/rscons/version.rb") =~ /VERSION = "(.+)"/
  VERSION = $1
else
  raise "Could not determine version."
end
PROG_NAME = "rscons"
START_FILE = "bin/#{PROG_NAME}"
LIB_DIR = "lib"
DIST = "dist"

files_processed = {}
combined_file = []

combine_files = lambda do |file|
  File.read(file, mode: "rb").each_line do |line|
    if line =~ /^\s*require(?:_relative)?\s*"(.*)"$/
      require_name = $1
      if require_name =~ %r{^#{PROG_NAME}(?:/.*)?$}
        path = "#{LIB_DIR}/#{require_name}.rb"
        if File.exist?(path)
          unless files_processed[path]
            files_processed[path] = true
            combine_files[path]
          end
        else
          raise "require path #{path.inspect} not found"
        end
      else
        combined_file << line
      end
    else
      combined_file << line
    end
  end
end

combine_files[START_FILE]

# Strip Ruby comment lines and empty lines to save some space, but do not
# remove lines that are in heredoc sections. This isn't terribly robust to be
# used in the wild, but works for the heredoc instances for this project.
stripped = []
heredoc_end = nil
combined_file.each do |line|
  if line =~ /<<-?([A-Z]+)/
    heredoc_end = $1
  end
  if heredoc_end and line =~ /^\s*#{heredoc_end}/
    heredoc_end = nil
  end
  if line !~ /#\sspecs/
    if heredoc_end or line !~ /^\s*(#[^!].*)?$/
      stripped << line
    end
  end
end

license = File.read("LICENSE.txt").gsub(/^(.*?)$/) do |line|
  if line.size > 0
    "# #{line}"
  else
    "#"
  end
end

compressed_script = Zlib::Deflate.deflate(stripped.join)
hash = Digest::MD5.hexdigest(compressed_script)
encoded_compressed_script = Base64.encode64(compressed_script).gsub("\n", "")
encoded_compressed_script_io = StringIO.new(encoded_compressed_script)
commented_encoded_compressed_script = ""
until encoded_compressed_script_io.eof?
  line = encoded_compressed_script_io.read(64)
  commented_encoded_compressed_script += "##{line}\n"
end

FileUtils.rm_rf(DIST)
FileUtils.mkdir_p(DIST)
File.open("#{DIST}/#{PROG_NAME}", "wb", 0755) do |fh|
  fh.write(<<EOF)
#!/usr/bin/env ruby

#{license}

BASE64CHARS = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/"

def base64_decode(s)
  out = ""
  v = 0
  bits = 0
  s.each_char do |c|
    if cv = BASE64CHARS.index(c)
      v = (v << 6) | cv
      bits += 6
    elsif c == "="
      break
    end
    if bits >= 8
      out += (v >> (bits - 8)).chr
      v &= 0xFFFFFFFF >> (32 - (bits - 8))
      bits -= 8
    end
  end
  out
end

script = File.join(File.dirname(__FILE__), ".rscons-#{VERSION}-#{hash}.rb")
unless File.exist?(script)
  if File.read(__FILE__, mode: "rb") =~ /^#==>(.*)/m
    require "zlib"
    encoded_compressed = $1
    compressed = base64_decode(encoded_compressed)
    if ENV["rscons_dist_specs"]
      require "digest/md5"
      if Digest::MD5.hexdigest(compressed) != "#{hash}"
        raise "Hash mismatch when decompressing rscons executable"
      end
    end
    inflated = Zlib::Inflate.inflate(compressed)
    File.open(script, "wb") do |fh|
      fh.write(inflated)
    end
  else
    raise "Error expanding rscons executable"
  end
end
load script
if __FILE__ == $0
  Rscons::Cli.new.run(ARGV)
end
#==>
#{commented_encoded_compressed_script}
EOF
end
