#! /usr/bin/env ruby
# encoding: UTF-8

require 'net/http'
require 'uri'
require 'stringio'
require 'zlib'
require 'rss'
require 'yaml'

def http_get_chunked (url, prefix = nil, headers = {}, &block)
    url = URI.parse url
    STDERR.print "#{prefix} " if prefix

    chunk_loop = %w{/ - \\ |}
    chunk_i = 0

    body = ""
    Net::HTTP.start(url.host, url.port) do |http|
        http.request_get(url.request_uri, headers) do |res|
            unless res.is_a? Net::HTTPSuccess
                raise Error.new("Failed to get #{url} (HTTP #{res})")
            else
                len = res['content-length'] ? res['content-length'].to_i : nil
                res.read_body do |chunk|
                    body += chunk
                    if len
                        STDERR.printf "\r%s %.2f%%", prefix, body.size * 100.0 / len if prefix
                    else
                        STDERR.print "\r#{prefix} #{chunk_loop[chunk_i]}"
                        chunk_i = (chunk_i + 1) % chunk_loop.length
                    end
                    yield chunk, res if block
                end
                # extra whitespace to clean the 'junk' from the progress display
                STDERR.puts "\r#{prefix} 100%   \r#{prefix} 100%" if prefix
            end
        end
    end
    body
end

def http_get (url, prefix = nil, &block)
    gzip = nil
    body = http_get_chunked(url, prefix, { 'Accept-Encoding' => "gzip" }) do |x,res|
        gzip = res["Content-Encoding"] && res["Content-Encoding"] == "gzip" if gzip.nil?
    end
    Zlib::GzipReader.wrap(StringIO.new body.dup) {|gz| body = gz.read} if gzip

    if block
        yield body
    else
        body
    end
end

class TTInfo < Hash
    include Comparable

    @@tie_break = []

    def TTInfo.tie_break= (list)
        @@tie_break = list
    end

    def hash
        [self[:name], self[:ep]].hash
    end

    def eql? (other)
        [self[:name], self[:ep]] == [other[:name], other[:ep]]
    end

    def <=> (other)
        return nil unless other.respond_to? :[]
        (%w{name ep} + @@tie_break).each do |i|
            t = self[i.to_sym] <=> other[i.to_sym]
            return t if t != 0
        end
        return 0
    end
end

class TTEntry
    include Comparable

    @@Attrs = [:id, :title, :link, :torrent, :size, :category, :info,
               :authorized, :magnet, :comment, :date, :guid]

    @@Attrs.each { |attr| attr_accessor attr }

    def initialize (entry)
        self.title = entry.title.gsub("_", " ")
        self.link = entry.link
        self.date = entry.pubDate

        # RSS::Parse treats guid and category specially
        # Its documentation also forgets to mention how to
        # extract the information from them.
        # So we want to stringify them...
        self.guid = entry.guid.to_s
        self.category = entry.category.to_s
        # ...and remove their extraneous tagging
        self.guid.sub!(/^.*id>(.+?)<\/gu.*$/u) { $1 }
        self.category.sub!(/^.*ry>(.+?)<\/cat.*$/u) { $1 }

        # category is meant to be used as a hash key
        self.category = self.category.to_sym

        self.guid.match(/id=(\d+)/) { self.id = $1.to_i }

        init_parsedesc!(entry.description)
        init_fixnyaa!
    end

    def inspect
        h = {}
        @@Attrs.each do |attr|
            h[attr] = self.send attr
        end
        h.inspect
    end

    def <=> (other)
        if other.is_a? TTEntry
            self.id <=> other.id
        elsif other.is_a? Integer
            self.id <=> other
        end
    end

    private

    def init_parsedesc!(desc)
        if desc =~ /Torrent: <a href="([^"]+)">/u
            self.torrent = $1
        else
            self.torrent = self.link
        end

        if desc =~ /Size: (\d+(?:.\d+).?B)/u
            self.size = $1
        end

        self.authorized = !!(desc =~ /Authorized: Yes/u)

        if desc =~ /href="(magnet:[^"]+)"/u
            self.magnet = $1
        end

        if desc =~ /Comment: (.*)$/u
            self.comment = $1
        end
    end

    def init_fixnyaa!
        [self.link, self.torrent].each do |url|
            url.sub!(/page=torrentinfo/u, "page=download")
        end
    end
end

class TTCategory < Array
    attr_accessor :name
    def initialize (catname)
        self.name = catname
    end

    def <=> (other)
        if other.is_a? TTCategory
            self.name <=> other.name
        else
            super <=> other
        end
    end
end

class TTEntries < Array
    def accept (settings)
        TTEntries.new(select{|e| settings.entry_ok? e})
    end

    def accept! (settings)
       TTEntries.new(select!{|e| settings.entry_ok? e})
    end

    def filter_version_duplicates
        name_and_ep = {}
        select{|e| e.info[:name]}.compact.each {|e| (name_and_ep[e.info] ||= []) << e}
        TTEntries.new((select{|e| !e.info[:name]} + name_and_ep.values.map{|x| x.max_by {|e| e.info}}).sort)
    end
end

class TTFeed
    attr_accessor :entries, :category, :prev_last_id, :last_id
    def initialize
        self.entries = TTEntries.new
        self.category = {}
        self.prev_last_id = self.last_id = -1
    end

    def update (url)
        add_new_items fetch_rss(url)
    end

    def fetch_rss (url)
        RSS::Parser.parse http_get(url, "Fetching RSS...")
    end

    def inspect
        s = ""
        self.entries.each do |entry|
            s += entry.inspect
            s += "\n------\n"
        end
        s.chomp!
    end

    def add_new_items (rss)
        new_last_id = self.last_id
        rss.items.each do |i|
            entry = TTEntry.new i
            if entry > self.last_id
                self.entries << entry
                entry > new_last_id and new_last_id = entry.id
            end
        end

        self.entries.sort!
        self.entries.each do |entry|
            if entry > self.last_id
                add_to_category entry.category, entry
            end
        end

        self.prev_last_id = self.last_id
        self.last_id = new_last_id
    end

    def accept (settings)
        self.entries.accept(settings)
    end

    def accept! (settings)
        self.entries.accept!(settings)
    end

    private
    def add_to_category (cat, entry)
        unless self.category[cat]
            self.category[cat] = TTCategory.new cat
        else
            self.category[cat] << entry
        end
    end
end

class TTSettings
    @@defaults = <<EOF
---
accept:
# Entries are only accepted if all present attributes match
# Conversely, any missing attribute is ignored for filtering purposes
# You can use regexp named captures as filtering attributes, such as "res"
# Use macros to make your life easier, see the "defines" section
# NOTE: all underscores in titles are converted to spaces before filtering
# NOTE: the authorized field only works with tokyotosho
# NOTE: the category field's content is source-dependent
- title: is a regular expression
  descr: a dash indicates a new entry
  note: indentation is important
  sample_entry: true
- examplemacro: Use macros like this
  examplemacro2: [ or this, for multiple argument, macros ]
  sample_entry: true
- examplemacro3:
  - or this
  - if the shortand fails
  sample_entry: true
# You can delete the above samples
deny:
# Parsed the same as the accept list
# Anything that matches these is ignored
# The deny list is processed before the accept list

# Order that variables are checked in order to tie break files with the same name and ep#
# Variables are checked in order until one is different
# When the different variable is found, the entry with the highest value is kept
tie_break: [ res, bit, ver ]
# URL to the RSS feed to be processed. Make sure to uncheck "anti-page widening"
# The zwnj=0 in the included URL is the variable that disables widening.
rss: https://www.tokyotosho.info/rss.php?zwnj=0
# Time in seconds to wait between polls to the RSS feed
# Set to 0 to disable polling and only run once.
poll: 7200
# Torrent save actions
# if save: is empty, ttrss will just print the name + URL of any entry that is accepted
# unless save is empty, ttrss saves the id of accepted files to ttrss.id.lst
save:
  # dir will download .torrent files to the specificed path (must exist)
  dir: torrents/
  # urlfile will output URLs to the .torrent files to the specificed file
  # use "-" for stdout (the quotes are important)
  #urlfile: "-"
  # magnetfile behaves the same as urlfile, but outputs magnet URIs
  # only works when using tokyotosho's feed
  #magnetfile: "-"


defines:
# Macros that can be called by other macros or by accept/deny filters
# Examples that are called from the sample entries in accept:
  examplemacro:
    title: $1
  examplemacro2:
    examplemacro: $1, $2 $3
    authorized: true
  examplemacro3:
    examplemacro2:
    - $1
    - use these if the shortand lists give syntax errors
    - $2
# When a macro is called, its contents are simply inserted in place of the macro call
# A macro's elements can insert arguments by using $1, $2, $3, ..., $9
# When a macro receives multiple arguments, they have to be put on a list
# See the invocations under accept for reference

# Regular expression tips:
# The title attribute is parsed as a regexp and matched against the rss item's title
# Try to use as much as possible of the title in the regexp to avoid false positives
# NOTE: don't use underscores in the regexps; underscores are converted to spaces beforehand
# Use the following named captures to help ttrss and the macro users:
## (?<name>regexp_to_match_name)   # for the series' name
## (?<group>regexp_to_match_group) # for the group's name
## (?<ep>\d+)(?:-(?<endep>\d+))?   # for the episode number
## (?:v(?<ver>\d+))?               # for the version tag
## (?i:(?<crc>[0-9a-f]{8}))        # for the CRC32
## (?<res>\d+)                     # for the integer height of the resolution
## (?<bit>\d+)                     # for the integer bit depth marker (usually 10-bit or 8-bit)
EOF

    def initialize
        # TODO: should try on $HOME first
        @yaml_path = "ttrss.yaml"
        @id_path = "ttrss.id.lst"

        unless File.exists? @yaml_path
            File.open(@yaml_path, "w") { |f| f.puts @@defaults }
            puts "Wrote new config file to #{@yaml_path}"
            puts "Customize #{@yaml_path} before rerunning ttrss"
            exit
        end

        @ids = []

        @id_file = File.open(@id_path, File::RDWR|File::CREAT)
        @id_file.flock(File::LOCK_EX) # prevent multiple instances
        @id_file.each do |line|
            @ids << line.to_i
        end

        reload_settings
    end

    def reload_settings
        @yaml = filter_doc symbolify_keys Psych.load_file @yaml_path

        [:accept, :deny].each do |k|
            @yaml[k] = [] unless @yaml[k]
            @yaml[k].map!{|i| apply_defines i, @yaml[:defines]}
        end

        # we don't need this anymore
        @yaml.delete(:defines)

        compile_regexps! @yaml[:accept]
        compile_regexps! @yaml[:deny]

        TTInfo::tie_break = @yaml[:tie_break]

        if @save
            @save[:uf].close if @save[:uf] && !@save[:uf].tty?
            @save[:mf].close if @save[:mf] && !@save[:mf].tty?
        end

        @save = {}
        if @yaml[:save] && @yaml[:save].is_a?(Hash)
            @yaml[:save].each do |meth,param|
                if meth == :urlfile
                    @save[:uf] = param == "-" ? STDOUT : File.open(param, "a")
                elsif meth == :magnetfile
                    @save[:mf] = param == "-" ? STDOUT : File.open(param, "a")
                elsif meth == :dir
                    @save[:dir] = param
                end
            end
        end
    end

    def rss
        @yaml[:rss]
    end

    def poll
        @yaml[:poll]
    end

    def entry_ok? (entry)
        raise ArgumentError unless entry.is_a? TTEntry

        !list_ok?(@yaml[:deny], entry) and list_ok?(@yaml[:accept], entry)
    end

    def entry_save! (entry)
        if @save.empty?
            STDERR.puts "Accepted \"#{entry.title}\" (#{entry.link})"
            return nil
        end

        return nil if @ids.include? entry.id

        @save[:uf].puts(entry.torrent) if @save[:uf]
        @save[:mf].puts(entry.magnet) if @save[:mf]

        begin
            if (dir = @save[:dir])
                File.open("#{dir}/#{entry.title}.torrent", "wb") do |f|
                    http_get_chunked(entry.link,
                            "Fetching \"#{entry.title}.torrent\"...") do |chunk|
                        f.write chunk
                    end
                end
            end
            # TODO: retry downloading on failure
            # TODO: download progress (though .torrents are tiny)

            push_ids! entry.id
        end
    end

    private

    def push_ids! (id)
        @ids << id
        @id_file.puts id
    end

    def list_ok? (list, entry)
        list.each do |e|
            match = nil
            if e.each { |k,v|
                s = nil
                s = entry.send(k) if entry.respond_to? k
                # some elements of entry are kept as symbols for hash access
                # but they need to be compared against the yaml entry (a string)
                # rather than intern the yaml entry, stringify the symbol
                s = s.to_s if s.is_a? Symbol

                if v.is_a?(Array) && s
                    # at least one match
                    break false unless v.any? {|e| s == e}
                elsif v.is_a?(Regexp) && s
                    # regexps must match
                    break false unless (match = s.match(v))
                elsif match && match.names.include?(k.to_s)
                    # if this is present in the match, keep
                elsif s.nil?
                    raise ArgumentError.new("Selector #{k} is not a standard selector nor a named capture in title's regexp")
                else
                    # everything else must be identical
                    break false unless s == v
                end } then
                avail = %w{name ep endep ver crc group res bit} & match.names
                info = TTInfo[avail.map {|w| [w.to_sym, match[w]]}]

                info[:endep] ||= info[:ep]

                # these are integers
                %w{ep endep ver bit res}.map do |w|
                    w = w.to_sym
                    info[w] = info[w] ? info[w].to_i : -1
                end

                info[:eps] = info[:ep]..info[:endep]

                # allow further filtering by regexp named capture
                to_check = e.keys & info.keys
                return false unless to_check.all? do |k|
                    if info[k].is_a? Range
                        info[k] === e[k].to_i
                    elsif info[k].is_a? Integer
                        info[k] == e[k].to_i
                    else
                        info[k] == e[k]
                    end
                end

                entry.info = info

                return true
            end

        end
        false
    end

    def filter_doc (h)
        if h.is_a? Hash
            Hash[h.reject{|k,v| k == :explanation}.map{|k,v| [k, filter_doc(v)]}]
        elsif h.is_a? Array
            h.map{|e| e.is_a?(Hash) && e[:sample_entry] ? nil : filter_doc(e)}.compact
        else
            h
        end
    end

    def symbolify_keys (h)
        if h.is_a? Hash
            Hash[h.map { |k,v| [k.to_sym, symbolify_keys(v)] }]
        elsif h.is_a? Array
            h.map { |e| symbolify_keys(e) }
        else
            h
        end
    end

    def apply_args (e, args)
        args = [args] unless args.is_a? Array
        if e.is_a? Array
            e.map do |i|
                apply_args i, args
            end
        elsif e.is_a? String
            e.gsub(/(?<!\\)\$(\d)/) do |m|
                i = $1.to_i
                if i > args.length
                    raise ArgumentError.new("Argument $#{i} to \"#{e}\" was not provided")
                end
                args[i-1]
            end
        else
            e
        end
    end

    def apply_defines (target, defines)
        return { :title => target } if target.is_a? String
        unless target.is_a? Hash
            raise ArgumentError.new("Don't know how to deal with #{target.class}")
        end

        ret = target.dup
        while (defines.keys & ret.keys).length > 0
            r = {}
            ret.each do |k,v|
                if defines.keys.include? k
                    defines[k].each do |def_k,sub|
                        r[def_k] = apply_args sub, v
                    end
                else
                    r[k] = v
                end
            end
            ret = r
        end
        ret
    end

    def compile_regexps! (entries)
        if entries
            entries.map! do |e|
                if e.is_a? Hash
                    e[:title] = Regexp.new(e[:title]) if e[:title]
                else
                    e = Regexp.new(e)
                end
                e
            end
        end
    end
end

class TTMain
    def logs (str)
        STDERR.puts str if @verbose
    end

    def initialize(verbose = true)
        @verbose = verbose
        @feed = TTFeed.new

        logs "Loading settings..."
        load_settings

        if (poll = @settings.poll) && poll > 0
            while poll && poll > 0
                process_accept refresh_feed
                logs "Sleeping for #{poll} seconds."
                sleep poll

                # TODO: listen to SIGHUP to wakeup from sleep

                logs "Reloading settings..."
                load_settings
                poll = @settings.poll
            end
        else
            process_accept refresh_feed
        end
    end

    def process_accept (list)
        list.each do |e|
            @settings.entry_save! e
        end
    end

    def refresh_feed
        @feed.update @settings.rss

        logs "Filtering..."
        @feed.accept(@settings).filter_version_duplicates
    end

    def load_settings
        @settings = TTSettings.new
    end
end

TTMain.new
