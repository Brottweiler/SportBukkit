require 'digest'
require 'pathname'
require 'rake'

def info(msg)
    puts "\e[32m#{msg}\e[0m"
end

def warning(msg)
    puts "\e[33m#{msg}\e[0m"
end

def error(msg)
    puts "\e[31m#{msg}\e[0m"
end

def relative_path(path, from: nil)
    pn = Pathname.new(path)
    if pn.absolute?
        pn = pn.relative_path_from(from || Pathname.pwd)
    end
    pn.to_s
end

def clean(*paths)
    paths.each do |path|
        if File.exists?(path)
            sh "rm", "-rf", path
        end
    end
end

def download(file:, url:, md5:)
    if File.exists?(file)
        cached_md5 =  Digest::MD5.file(file).hexdigest
        if md5 == Digest::MD5.file(file).hexdigest
            info "Using cached #{file}"
            return
        end
        warning "Found a cached but corrupted version of #{file} (expected MD5 #{md5}, got #{cached_md5})"
        FileUtils.rm(file)
    end

    info "Downloading #{url}"
    sh "curl", "-o", file, url

    actual_md5 = Digest::MD5.file(file).hexdigest
    unless md5 == actual_md5
        error "Downloaded file is corrupted (expected MD5 #{md5}, got #{actual_md5}"
        raise
    end
end

def maven(*goals)
    sh %{MAVEN_OPTS="$MAVEN_OPTS -Xmx512M" mvn #{goals.join(' ')}}
end

module Git
    extend self
    extend FileUtils

    def init(repo)
        unless File.exists?(File.join(repo, ".git"))
            info "Initializing git in #{repo}"
            sh "git", "init", repo
        end
    end

    def clone(from:, to:)
        unless File.exists?(File.join(to, ".git"))
            info "Cloning #{from} to #{to}"
            sh "git", "clone", from, to
        end
    end

    def submodule_update(path)
        info "Checking out submodule #{path}"
        sh "git", "submodule", "update", "--init", path
    end

    def branch(branch)
        sh "git", "checkout", branch do |ok, res|
            unless ok
                sh "git", "branch", "-f", branch
                sh "git", "checkout", branch
            end
        end
    end

    def remote_add(remote:, url:)
        unless `git remote`.split.include?(remote)
            info "Adding remote #{remote} at #{url}"
            sh "git", "remote", "add", remote, url
        end
    end

    def reset(remote:, branch:)
        ref = "refs/remotes/#{remote}/#{branch}"
        info "Resetting to #{ref}"
        sh "git", "fetch", remote, branch
        sh "git", "reset", "--hard", "#{remote}/#{branch}"
    end

    def apply(patches)
        patches = relative_path(patches)
        info "Applying #{Dir[File.join(patches, "*.patch")].size} patches from #{patches}"
        if `git status` =~ /You are in the middle of an am session/
            sh "git am --abort"
        end
        sh "git clean -df"
        sh "git am --3way --ignore-whitespace --committer-date-is-author-date #{Shellwords.escape(patches)}/*.patch" do |ok, res|
            unless ok
                error "A patch did not apply cleanly"
                raise
            end
        end
    end

    def assert_clean_work_tree
        sh "git update-index -q --ignore-submodules --refresh"
        sh "git diff-files --quiet --ignore-submodules --" do |ok, res|
            unless ok
                error "Cannot apply patches to unclean work tree"
                sh "git diff-files --name-status -r --ignore-submodules --" # show the changes
                raise
            end
        end
        sh "git diff-index --cached --quiet HEAD --ignore-submodules --" do |ok, res|
            unless ok
                error "Cannot apply patches to unclean work tree"
                sh "git diff-index --cached --name-status -r --ignore-submodules HEAD --" # show the changes
                raise
            end
        end
    end

    def head_commit_message
        `git log -n 1 --format=%s`.chomp
    end

    def generate_patches(from:, patches:)
        patches = relative_path(patches)
        sh "git", "format-patch", "--no-stat", "--no-signature", "-N", "-o", patches, from
        Dir[File.join(patches, "*.patch")].each do |patch|
            lines = File.read(patch).lines
            File.open(patch, 'w') do |io|
                if lines[0] =~ /^From \h+/
                    # Remove the initial "From sha date" line
                    lines = lines[1..-1]
                end

                lines.reject do |line|
                    # Remove "index sha..sha mode" lines
                    line =~ /^index \h+\.\.\h+ \d+\s*$/
                end.each do |line|
                    io.write(line)
                end
            end
        end
    end

    def export(from:, to:)
        clean to
        mkdir_p to
        to = File.absolute_path(to)
        Dir.chdir from do
            sh "git archive HEAD | tar -x -C #{to}"
        end
    end

    module Rake
        extend self

        def repo(*args, &block)
            RepoTask.define_task(*args, &block)
        end

        def submodule(*args)
            repo(*args) do |task|
                Git.submodule_update(task.file)
            end
        end

        class RepoTask < ::Rake::FileTask
            def needed?
                !File.exists?(File.join(name, ".git"))
            end
        end
    end
end
