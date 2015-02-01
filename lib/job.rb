#!/usr/bin/ruby

LKP_SRC ||= ENV['LKP_SRC']
LKP_SERVER ||= 'inn'

require "#{LKP_SRC}/lib/result.rb"
require 'fileutils'
require 'yaml'
require 'json'
require 'set'
require 'pp'

def deepcopy(o)
	Marshal.load(Marshal.dump(o))
end

def restore(ah, copy)
	if ah.class == Hash
		ah.clear.merge!(copy)
	elsif ah.class == Array
		ah.clear.concat(copy)
	end
end

def expand_shell_var(env, o)
	s = o.to_s
	return s if `hostname`.chomp == LKP_SERVER
	if s.index('$')
		f = IO.popen(env, ['/bin/bash', '-c', 'eval echo "' + s + '"'], 'r')
		s = f.read.chomp
		f.close
	elsif s.index('/dev/disk/')
		files = {}
		s.split.each { |f|
			Dir.glob(f).each { |d| files[File.realpath d] = d }
		}
		s = files.keys.sort_by { |dev|
			dev =~ /(\d+)$/
			$1.to_i
		}.join ' '
	end
	return s
end

def expand_toplevel_vars(env, hash)
	vars = {}
	hash.each { |key, val|
		case val
		when Hash
			next
		when nil
			vars[key] = nil
		when Array
			vars[key] = expand_shell_var(env, val[0]) if val.size == 1
		else
			vars[key] = expand_shell_var(env, val)
		end
	}
	return vars
end

def string_or_hash_key(h)
	if h.class == Hash
		# assert h.size == 1
		return h.keys[0]
	else
		return h
	end
end

def strip_trivial_array(a)
	if a.class == Array
		return a[0]
	else
		return a
	end
end

def for_each(ah)
	if ah.class == Hash
		ah.each { |k, v|
			yield ah, k, v
		}
	else
		yield ah, nil, nil
	end
end

def for_each_program(ah)
	for_each(ah) { |h, k, v|
		# puts k
		if $programs.include? k
			yield h, k, v
		elsif Hash === v
			for_each_program(v) { |h, k, v|
				yield h, k, v
			}
		end
	}
end

def for_each_program_or_param(ah)
	$dims_to_expand ||= Set.new [ 'kconfig', 'commit', 'rootfs' ]
	for_each(ah) { |h, k, v|
		# puts k
		if $programs.include?(k) or $dims_to_expand.include?(k)
			if (v.class == Array and v.size > 1) or (v.class == Hash and v.size >= 1)
				options = {}
				if $programs[k] and $programs[k].size > 0
					`#{LKP_SRC}/bin/program-options #{$programs[k]}`.each_line { |line|
						type, name = line.split
						options[name] = type
					}
				end
				if options.include? string_or_hash_key(strip_trivial_array(v)) 
					if v.class == Hash
						v.each { |kk, vv| yield kk, vv }
					# elsif v.class == Array
						# v.each { |kk| yield kk, vv }
					end
				else
					yield h, k, v
				end
			else
				yield h, k, v
			end
		elsif Hash === v
			for_each_program_or_param(v) { |h, k, v|
				yield h, k, v
			}
		end
	}
end

# programs[script] = full/path/to/script
def __create_programs_hash(glob)
	$programs = {}
	Dir.glob("#{LKP_SRC}/#{glob}").each { |path|
		next if File.directory?(path)
		next if not File.executable?(path)
		file = File.basename(path)
		next if file == 'wrapper'
		if $programs.include? file
			STDERR.puts "Conflict names #{$programs[file]} and #{path}"
			next
		end
		$programs[file] = path
	}
end

def create_programs_hash(glob)
	$programs_cache ||= {}
	if $programs_cache[glob]
		$programs = $programs_cache[glob]
		return
	end

	__create_programs_hash(glob)

	$programs_cache[glob] = $programs
end

def atomic_save_yaml_json(object, file)
	temp_file = file + "-#{$$}"
	File.open(temp_file, mode='w') { |file|
		if temp_file.index('.json')
			file.write(JSON.pretty_generate(object, :allow_nan => true))
		else
			file.write(YAML.dump(object))
		end
	}
	FileUtils.mv temp_file, file, :force => true
end

def rootfs_filename(rootfs)
	strip_trivial_array(rootfs).split(/[^a-zA-Z0-9._-]/)[-1]
end

class Job

	def update(hash, top = false)
		@job ||= {}
		if top
			@job = hash.merge @job
		else
			@job.update hash
		end
	end

	def load_head(jobfile, top = false)
		return nil unless File.exist? jobfile
		job = YAML.load_file jobfile
		self.update(job, top)
	end

	def load(jobfile)
		begin
			yaml = File.read jobfile
			@jobs = []
			YAML.load_stream(yaml, jobfile) do |hash|
				@jobs << hash
			end
			@job ||= {}
			@job.update @jobs.shift
		rescue Errno::ENOENT
			return nil
		rescue Exception
			STDERR.puts "Failed to open job #{jobfile}: #{$!}"
			if File.size(jobfile) == 0
				STDERR.puts "Removing empty job file #{jobfile}"
				FileUtils.rm jobfile
			end
			raise
		end
	end

	def save(jobfile)
		atomic_save_yaml_json @job, jobfile
	end

	def each_job
		create_programs_hash "{setup,tests}/**/*"
		last_item = ''
		for_each_program_or_param(@job) { |h, k, v| last_item = k }
		for_each_program_or_param(@job) { |h, k, v|
			if Array === v and v.size > 1
				copy = deepcopy(v)
				for_each(copy) { |hh, kk, vv|
					restore(v, copy)
					v.keep_if { |a, b| a == kk }
					# expand_one(job) { |job| yield job }
					each_job { yield self }
				}
				restore(v, copy)
				break
			elsif k == last_item
				yield self
			end
		}
	end

	def each_jobs(&block)
		each_job &block
		@jobs.each do |hash|
			@job.update hash
			each_job &block
		end
	end

	def each_param
		create_programs_hash "{setup,tests}/**/*"
		for_each_program(@job) { |h, k, v|
			options = {}
			if $programs[k].size > 0
				`#{LKP_SRC}/bin/program-options #{$programs[k]}`.each_line { |line|
					type, name = line.split
					options[name] = type
				}
			end
			if v.class == Hash
				v.each { |kk, vv| yield kk, options.include?(kk) ? strip_trivial_array(vv) : kk, options[kk] }
			elsif v.class == Array
				if v[0].class == Hash
					v[0].each { |kk, vv| yield kk, options.include?(kk) ? strip_trivial_array(vv) : kk, options[kk] }
				else
					yield k, v[0], options[k]
				end
			else
				yield k, v, options[k]
			end
		}
	end

	def each_program(glob)
		create_programs_hash(glob)
		for_each_program(@job) { |h, k, v|
			yield k, v
		}
	end

	def path_params
		path = ''
		each_param { |k, v, option_type|
			if option_type == '='
				if v and v != ''
					path += "#{k}=#{v}".tr('/$()', '_')
				else
					path += "#{k}".tr('/$()', '_')
				end
				path += '-'
				next
			end
			next unless v
			path += v.to_s.tr('/$()', '_')
			path += '-'
		}
		if path.empty?
			return 'defaults'
		else
			return path.chomp('-')
		end
	end

	def _result_root
		result_path = ResultPath.new
		result_path.update @job
		result_path['rootfs'] ||= 'debian-x86_64.cgz'
		result_path['rootfs'] = rootfs_filename result_path['rootfs']
		result_path['path_params'] = self.path_params
		result_path._result_root
	end

	def [](k)
		strip_trivial_array(@job[k])
	end

	def []=(k, v)
		@job[k] = v
	end

	def delete(k)
		@job.delete(k)
	end
end
