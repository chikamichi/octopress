# coding: utf-8

require 'fileutils'
require 'yaml'

module Octopress
  # Shared config mixin used by all Thor namespaced tasks defined below.
  #
  module Config
    module Inject; end

    def self.included(base)
      # Dynamically load the octopress conf and create dev-friendly accessors.
      YAML.load(File.open('_config.yml'))['octopress'].each_pair do |k,v|
        Inject.module_eval do
          define_method(k) { v }
        end
      end

      # Due to desc methods at class level, we need to both include and extend
      # our dynamically generated config accessors.
      base.send(:include, Inject)
      base.extend Inject

      # Some smart guessing of namespace and default class options, go figure.
      base.class_eval do
        if ancestors.include? Thor::Group
          namespace self.name.split('::').last.downcase.to_sym
        end

        class_option :verbose, :aliases => '-v', :desc => 'Whether to output informative debug'
        class_option :theme, :aliases => '-t', :default => 'classic', :desc => 'Perform the command in the context of this specific theme'
      end
    end

    # Enforce silent system calls, unless the --verbose option is passed.
    # One may either pass -v, --verbose or --[v|verbose]=[true|t|yes|y|1].
    #
    def run(cmd, *args)
      args = args.empty? ? {} : args.pop
      verbose = !!(options[:verbose] && options[:verbose].to_s.match(/(verbose|true|t|yes|y|1)$/i))
      super(cmd, args.merge(:verbose => verbose))
    end

    # Enforce green output by default.
    #
    # TODO: tell wycats *not* to perform such string manipulation in the prototype, one
    # cannot properly redef on top of that!
    #
    def say(message = "", color = nil, force_new_line = (message.to_s !~ /( |\t)$/))
      color ||= :green
      super
    end

    # Tail call optimized recursive configuration edition helper (whoa).
    #
    # @overload edit_config(config, key, new_value)
    #   @param [String] config configuration filename (relative to current directory)
    #   @param [#to_s, true, false] key config key to edit
    #   @param [#to_s, true, false] new_value
    # @overload edit_config(config, hash)
    #   @param [String] config configuration filename (relative to current directory)
    #   @param [Hash] hash like {'foo' => 'bar', :true => false}
    #
    def edit_config(config, *args)
      edit_config!(config, '', *args)
    end

    private

    def edit_config!(config, filecontent, *args)
      # TCO is a bit messy for Ruby won't do pattern matching. Here I rely on
      # the presence of the 'false' boolean in last position to discard between first
      # call and subsequent ones, and I also need to discard between Array and Hash
      # support, all of that to init the 'filecontent' accumulator. It's fairly easy though!
      if args.length == 1 || !args.first.is_a?(Hash)
        # first time here, read the conf
        filecontent = IO.read(config)
      else
        # within recursion, remove the 'false' boolean and proceed
        args.pop
      end

      args = args[0].is_a?(Hash) ? args.pop : args = {args[0] => args[1]}

      if args.empty?
        File.open(config, 'w') do |f|
          f.write filecontent
        end and return
      end

      key, new_value = args.shift

      if config.end_with?('.rb')
        filecontent.sub!(/#{key.to_s}(\s*)=(\s*)(["'])[\w\-\/]*["']/, "#{key.to_s}\\1=\\2\\3#{new_value}/\\3")
      elsif config.end_with?('.yml')
        filecontent.sub!(/^(\s*)#{key}:(\s+)([^(\s*#)]+)(.*)/, "\\1#{key}:\\2#{new_value}\\4")
      else
        say "edit_config(#{config}, #{args} unable to process the specified conf file (.rb or .yml?)", :red
        return
      end

      edit_config!(config, filecontent, args, false)
    end
  end

  # "Singleton" task to setup a brand new Octopress in one step.
  #
  class Setup < Thor::Group
    include FileUtils
    include Thor::Actions
    include Config

    def self.source_root
      File.dirname(__FILE__)
    end

    desc "Initial setup for your Octopress blog. To install a different theme (different location), pass the -t option."
    class_option :theme, :aliases => '-t', :default => 'classic', :desc => "Blog's theme. Setup will copy the default theme into the path of Jekyll's generator."
    def install
      say "## Copying '" + options[:theme] + "' theme assets into ./#{source_dir} and ./sass"

      in_root do
        mkdir_p source_dir
        cp_r "#{themes_dir}/#{options[:theme]}/source/.", source_dir

        mkdir_p "sass"
        cp_r "#{themes_dir}/#{options[:theme]}/sass/.", "sass"

        mkdir_p "#{source_dir}/#{posts_dir}"
        mkdir_p public_dir
      end
    end
  end

  class Admin < Thor
    include Thor::Actions
    include Config

    namespace :admin

    desc 'generate', "Generate jekyll site"
    def generate
      say "## Generating site with Jekyll"
      in_root { run "jekyll" }
      say '## Done'
    end

    desc 'watch', "Watch the site and regenerate when it changes"
    def watch
      say "## Watching incoming changes, regenerating on the fly"
      in_root { run "trap 'kill $jekyllPid $compassPid' Exit; jekyll --auto & jekyllPid=$!; compass watch & compassPid=$!; wait" }
    end

    desc 'preview', "preview the site in a web browser"
    def preview
      say "## Launching webserver to preview your site"
      in_root { run "trap 'kill $jekyllPid $compassPid' Exit; jekyll --auto --server & jekyllPid=$!; compass watch & compassPid=$!; wait" }
    end

    desc 'clean', "Clean out caches: _code_cache, _gist_cache, .sass-cache"
    def clean
      in_root { run "rm -rf _code_cache/** _gist_cache/** .sass-cache/**" }
      say '## Done'
    end

    desc 'isolate POST_TITLE', "Move all posts but the specified one to a temporary stash location, so regenerating the site happens much quicker"
    def isolate(filename)
      in_root do
        stash_dir = "#{source_dir}/#{stash_dir}"
        FileUtils.mkdir(stash_dir) unless File.exist?(stash_dir)
        Dir.glob("#{source_dir}/#{posts_dir}/*.*") do |post|
          FileUtils.mv post, stash_dir unless post.match /\d{4}-\d{2}-\d{2}-#{filename}\.\w*/
        end
      end
      say '## Done. Run thor admin:integrate to consolidate your blog posts again after thor admin:generate.'
    end

    desc 'integrate', "Move all stashed posts back into the posts directory, ready for site generation."
    def integrate
      in_root { FileUtils.mv Dir.glob("#{source_dir}/#{stash_dir}/*.*"), "#{source_dir}/#{posts_dir}/" }
      say '## Done'
    end
  end

  class Update < Thor
    include FileUtils
    include Thor::Actions
    include Config

    namespace :update

    desc 'style', "Move sass to sass.old, install sass theme updates, replace sass/custom with sass.old/custom"
    def style
      in_root do
        if File.directory?("sass.old")
          say "## Removing existing sass.old directory", :yellow
          run "rm -r sass.old"
        end
      end

      say "## Moving styles to sass.old/"
      in_root do
        run "mv sass sass.old"
        say "## Updating Sass"
        run "mkdir -p sass; cp -R #{themes_dir}/" + options[:theme] + "/sass/ sass/"
        cp_r "sass.old/custom/.", "sass/custom"
      end
    end

    desc 'source', "Move source to source.old, install source theme updates, replace source/_includes/navigation.html with source.old's navigation"
    def source
      in_root do
        if File.directory?("#{source_dir}.old")
          say "## Removing existing #{source_dir}.old directory", :yellow
          run "rm -r #{source_dir}.old"
        end
      end

      say "## Moving #{source_dir} into #{source_dir}.old/"
      in_root { run "mv #{source_dir} #{source_dir}.old" }

      say "## Updating #{source_dir} ##"
      in_root do
        run "mkdir -p #{source_dir}; cp -R #{themes_dir}/" + options[:theme] + "/source/. #{source_dir}"
        run "cp -Rn #{source_dir}.old/. #{source_dir}"
        run "cp -Rf #{source_dir}.old/_includes/custom/. #{source_dir}/_includes/custom/"
      end
    end
  end

  class New < Thor
    include FileUtils
    include Thor::Actions
    include Config
    require './plugins/titlecase.rb'

    namespace :new

    desc 'post POST_TITLE', "Begin a new post in #{source_dir}/#{posts_dir}/."
    def post(title = 'new-post')
      generated_at = Time.now
      filename  = "#{source_dir}/#{posts_dir}/#{generated_at.strftime('%Y-%m-%d')}"
      filename += "-#{title.downcase.gsub(/&/,'and').gsub(/[,'":\?!\(\)\[\]]/,'').gsub(/[\W\.]/, '-').gsub(/-+$/,'')}"
      filename += ".#{new_post_ext}"

      say "## Creating new post: #{filename}"
      create_file filename do
        system "mkdir -p #{source_dir}/#{posts_dir}";
        <<-EOS.squish
          ---
          layout: post
          title: \"#{title.gsub(/&/,'&amp;').titlecase}\"
          date: #{generated_at.strftime('%Y-%m-%d %H:%M')}
          comments: true
          categories:
          ---
        EOS
      end
    end

    desc 'page PAGE_TITLE', "Create a new page in #{source_dir}/(filename)/index.#{new_page_ext}"
    def page(filename = 'new-page')
      require './plugins/titlecase.rb'

      page_dir = source_dir
      filename = filename.dup.gsub(/\s$/, '')
      splitted = filename.match /^(.+\/)?([\s\w_-]+)(\.)?(\w+)*/

      unless splitted.nil?
        if splitted[1].nil? # simple string
          if splitted[3].nil?
            dir, filename, ext = splitted[2] + '/', 'index', splitted[4] || new_page_ext
          else
            dir, filename, ext = '', splitted[2], splitted[4] || new_page_ext
          end
        else # at least one '/'
          if splitted[3].nil?
            dir, filename, ext = splitted[1] + splitted[2] + '/', 'index', splitted[4] || new_page_ext
          else
            dir, filename, ext = splitted[1], splitted[2], splitted[4] || new_page_ext
          end
        end

        [dir, filename].map { |s| !s.nil? && s.gsub!(/[\s]/, '-') }

        page_title = filename
        filename = if dir.nil?
                     "#{source_dir}/#{filename}/index.#{ext}"
                   else
                     "#{source_dir}/#{dir}#{filename}.#{ext}"
                   end

        say "## Creating new page: #{filename}"
        create_file filename do
          <<-EOS.squish
            ---
            layout: page
            title: \"#{page_title.gsub(/[-_]/, ' ').titlecase}\"
            date: #{Time.now.strftime('%Y-%m-%d %H:%M')}
            comments: true
            sharing: true
            footer: true
            ---
          EOS
        end
      else
        say "Syntax error: #{filename} is not a valid page title/path", :red
      end
    end
  end

  class Deploy < Thor
    include FileUtils
    include Thor::Actions
    include Config

    namespace :deploy

    desc 'default', "Default deploy task as set in your configuration"
    def default
      in_root { remove_file 'toto' }
      invoke deploy_default.to_sym
    end

    desc 'rsync', "Deploy website via rsync"
    def rsync
      endpoint = "#{ssh_user}:#{document_root}"
      say "## Deploying website via rsync to #{endpoint}"
      in_root { run "rsync -avz --delete #{public_dir}/ #{endpoint}" }
    end

    desc 'push', "deploy public directory to github pages"
    def push
      say "## Deploying branch to Github Pages"
      (Dir["#{deploy_dir}/*"]).each { |f| remove_file(f) }

      say "## copying #{public_dir} to #{deploy_dir}"
      in_root { run "cp -R #{public_dir}/* #{deploy_dir}" }

      inside "#{deploy_dir}" do
        run "git add ."
        run "git add -u"
        say "## Commiting: Site updated at #{Time.now.utc}"
        message = "Site updated at #{Time.now.utc}"
        run "git commit -m '#{message}'"
        say "## Pushing generated #{deploy_dir} website"
        run "git push origin #{deploy_branch}"
        say "## Github Pages deploy complete"
      end
    end

    desc 'set_root DIRECTORY', "Update configuration to support publishing to the root or a subdirectory"
    def set_root(dir)
      dir = dir.match(/\//) ? '' : "/" + dir.sub(/(\/*)(.+)/, "\\2").sub(/\/$/, '')

      edit_config('config.rb', {
        :http_path        => "#{dir}",
        :http_images_path => "#{dir}/images",
        :http_fonts_path  => "#{dir}/fonts",
        :css_dir          => "public#{dir}/stylesheets"
      })

      edit_config('_config.yml', {
        'public_dir'    => "public#{dir}",
        'destination'   => "public#{dir}",
        'subscribe_rss' => "#{dir}/atom.xml",
        'root'          => "/#{dir.sub(/^\//, '')}"
      })

      in_root do
        remove_dir public_dir
        mkdir_p "#{public_dir}#{dir}"
      end
      say "## Site's root directory is now '/#{dir.sub(/^\//, '')}'"
    end

    desc 'config BRANCH_NAME', "Setup both the _deploy folder and the deploy branch"
    def config(branch)
      say "## Creating a clean #{branch} branch in ./#{deploy_dir} for Github pages deployment"

      inside "#{deploy_dir}" do
        run "git symbolic-ref HEAD refs/heads/#{branch}"
        run "rm .git/index"
        run "git clean -fdx"
        run "echo 'My Octopress Page is coming soon &hellip;' > index.html"
        run "git add ."
        run "git commit -m 'Octopress init'"
      end

      edit_config('_config.yml', {
        'deploy_branch'  => branch,
        'deploy_default' => 'pussh'
      })

      say "## Deployment configured. You can now deploy to the #{branch} branch by running thor deploy"
    end
  end
end
