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
                raise IOError.new("Failed to get #{url} (HTTP #{res})")
            else
                len = res['content-length'] ? res['content-length'].to_i : nil
                res.read_body do |chunk|
                    body += chunk
                    if len
                        STDERR.printf "\r%s %.2f%%", prefix, body.size * 100.0 / len if prefix
                    elsif prefix
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
    attr_accessor :entries, :category, :prev_last_id, :last_id, :count
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
        self.count = 0
        rss.items.each do |i|
            entry = TTEntry.new i
            if entry > self.last_id
                self.count += 1
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
    def initialize
        # TODO: should try on $HOME first
        @yaml_path = "ttrss.yaml"
        @id_path = "ttrss.id.lst"

        unless File.exists? @yaml_path
            puts "Copy ttrss.sample.yaml to ttrss.yaml and customize it before rerunning ttrss"
            exit
        end

        @ids = []

        @id_file = File.open(@id_path, File::RDWR|File::CREAT)
        unless @id_file.flock(File::LOCK_EX|File::LOCK_NB)
            raise RuntimeError.new("Another ttrss instance is already running")
        end
        @id_file.each do |line|
            @ids << line.to_i
        end

        reload_settings
    end

    def reload_settings
        @yaml = filter_doc symbolify_keys Psych.load_file @yaml_path

        [:accept, :deny].each do |k|
            @yaml[k] = [] unless @yaml[k]
            @yaml[k].map!{|i| apply_defines i}
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
        elsif e.is_a? Hash
            apply_defines e, args
        else
            e
        end
    end

    def apply_defines (target, args = nil)
        return { :title => target } if target.is_a? String
        unless target.is_a? Hash
            raise ArgumentError.new("Don't know how to deal with #{target.class}")
        end

        defines = @yaml[:defines]

        ret = target.dup
        while (defines.keys & ret.keys).length > 0
            r = {}
            ret.each do |k,v|
                if defines.keys.include? k
                    if defines[k].is_a? String
                        # XXX: HACK: SPECIAL CASE
                        # For allowing macro arguments to be calls to other macros
                        # This doesn't make sense if the other macro returns
                        # anything other than a simple string
                        return apply_args defines[k], v
                    else
                        defines[k].each do |def_k,sub|
                            # XXX: HACK: apply_args to the return of apply_args
                            # to allow macros to do argument replacing when
                            # macros return strings with argument places
                            r[def_k] = apply_args(apply_args(sub, v), args || target[k])
                        end
                    end
                else
                    r[k] = apply_args v, args || []
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
                @settings.reload_settings
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

        logs "Filtering #{@feed.count} entries..."
        @feed.accept(@settings).filter_version_duplicates
    end

    def load_settings
        @settings = TTSettings.new
    end
end

TTMain.new
