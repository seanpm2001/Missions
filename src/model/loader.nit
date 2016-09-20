# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
#      http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.
# Load mission and tracks from the file system

module loader

import missions
import markdown
private import md5

private import poset

redef class ConfigTree
	# Get a key as an Int, if any
	fun get_i(key: String): nullable Int do
		var value = self[key]
		if value == null then return null
		return value.to_i
	end
end

redef class AppConfig
	# Load all tracks that are subdirectories of `path`.
	fun load_tracks(path: String) do
		# Process files
		for f in path.files do
			var sub = path / f
			var t = sub / "track.ini"
			if t.file_exists then load_track(sub)
		end
	end

	# Load the track of the directory `path`.
	#
	# Returns the track, or `null` if there is a problem
	fun load_track(path: String): nullable Track do
		var desc = path / "track.md"
		if not desc.file_exists then return null

		var ini = new ConfigTree(path / "track.ini")

		# The internal name
		var name = ini["name"] or else path.basename

		# The public title
		var title = ini["title"]
		if title == null then
			print_error "{path}: no title in {ini}, fall-back to {name}"
			title = name
		end

		var title_id = title.strip_id

		var content = desc.to_path.read_all
		if content.is_empty then print_error "{path}: empty {desc}"
		var proc = new MarkdownProcessor
		proc.emitter.decorator = new DescDecorator(path, "data")
		var html = proc.process(content).write_to_string

		var track = new Track(title_id, title, html)

		var ls = ini["languages"]
		if ls != null then
			for l in ls.split(",") do
				l = l.trim
				track.default_languages.add l
			end
		else
			print_error "Track without languages: {track}"
		end

		var r = ini.get_i("reward")
		if r != null then track.default_reward = r

		self.tracks.save track
		track.load_missions(self, path)
		return track
	end
end

redef class Track
	# Load the missions from the directory `path`.
	fun load_missions(config: AppConfig, path: String) do
		var files = path.files.to_a
		default_comparator.sort(files)

		var missions = new POSet[Mission]
		var mission_by_name = new HashMap[String, Mission]

		# Process files
		for f in files do
			var ff = path / f
			var mission = ff / "mission.md"
			if not mission.file_exists then continue
			var ini = new ConfigTree(ff / "config.ini")

			var name = f.basename
			var title = ini["title"]
			if title == null then
				print_error "{name}: no title in {ini}"
				title = name
			end

			var content = mission.to_path.read_all
			if content.is_empty then print_error "{name}: no {mission}"
			var proc = new MarkdownProcessor
			proc.emitter.decorator = new DescDecorator(ff, "data")
			var html = proc.process(content).write_to_string

			var title_id = self.id + ":" + title.strip_id

			var m = new Mission(title_id, self, title, html)
			mission_by_name[name] = m

			m.path = ff

			var reqs = ini["req"]
			if reqs != null then for r in reqs.split(",") do
				r = r.trim
				m.parents.add r
			end

			m.solve_reward = ini.get_i("reward") or else default_reward

			var tg = ini.get_i("star.time.goal")
			if tg != null then
				var star = new TimeStar("Instruction CPU", 10, tg.to_i)
				m.add_star star
			end
			var sg = ini.get_i("star.size_goal")
			if sg != null then
				var star = new SizeStar("Taille du code machine", 10, sg.to_i)
				m.add_star star
			end
			var ls = ini["languages"]
			if ls != null then
				# Get the list of languages
				for l in ls.split(",") do
					l = l.trim
					m.languages.add l
				end
			else
				# Defaults to the track list, if any
				m.languages.add_all self.default_languages
			end


			# Load tests, if any.
			# This assume the Oto test file format:
			# * Testcases start with the line `===`
			# * input and output are separated  with the line `---`
			var tf = ff / "tests.txt"
			if tf.file_exists then
				var i = ""
				var o = ""
				var in_input = true
				var lines = tf.to_path.read_lines
				if lines.first == "===" then lines.shift
				lines.add "==="
				for l in lines do
					if l == "===" then
						var t = new TestCase(i, o)
						m.testsuite.add t
						i = ""
						o = ""
						in_input = true
					else if l == "---" then
						in_input = false
					else if in_input then
						i += l + "\n"
					else
						o += l + "\n"
					end
				end
			end

			print "{ff}: got «{m}»; {m.testsuite.length} tests. languages={m.languages.join(",")}"

			missions.add_node m
		end

		for m in missions do
			# The mangoid of the parents
			var reals = new Array[String]
			for r in m.parents do
				var rm = mission_by_name.get_or_null(r)
				if rm == null then
					print_error "{m}: unknown requirement {r}"
				else if missions.has_edge(rm, m) then
					print_error "{m}: circular requirement with {rm}"
				else
					missions.add_edge(m, rm)
					reals.add rm.id
				end
			end

			# replace parents' id and save
			m.parents.clear
			m.parents.add_all reals
			config.missions.save(m)
		end
	end

	# List of default allowed languages
	var default_languages = new Array[String]

	# Default reward for a solved mission
	var default_reward = 10
end

class DescDecorator
	super HTMLDecorator

	# The directory to find original local resources (links and images)
	var ressources_dir: String

	# Storage directory to put copied resources
	# Assume it will be served as is by nitcorn
	var data_dir: String

	# Copy a local resource to the storage directory.
	#
	# If it is successful, return a new link.
	# If the link is not local, return `null`.
	# If the resource is not found, return `null`.
	fun copy_ressource(link: String): nullable String
	do
		# Keep absolute links as is
		if link.has_prefix("http://") or link.has_prefix("https://") then
			return null
		end

		# Get the full path to the local resource
		var fulllink = ressources_dir / link
		var stat = fulllink.file_stat
		if stat == null then
			print_error "Error: cannot find local resource `{link}`"
			return null
		end

		# Get a collision-free name for the resource
		var hash = fulllink.md5
		var ext = fulllink.file_extension
		if ext != null then hash = hash + "." + ext

		# Copy the local resource in the resource directory of the catalog
		data_dir.mkdir
		var res = data_dir / hash
		fulllink.file_copy_to(res)

		# Produce a new absolute link for the HTML
		var new_link = "/" / data_dir / hash
		#print "{link} -> {new_link}; as {res}"
		return new_link
	end

	redef fun add_image(v, link, name, comment)
	do
		var new_link = copy_ressource(link.to_s)

		if new_link == null then
			super
		else
			super(v, new_link, name, comment)
		end
	end

	redef fun add_link(v, link, name, comment)
	do
		var new_link = copy_ressource(link.to_s)

		if new_link == null then
			super
		else
			super(v, new_link, name, comment)
		end
	end
end

redef class String
	# Replace sequences of non-alphanumerical characters by underscore.
	#
	# ~~~
	# assert "abcXYZ123_".strip_id == "abcXYZ123_"
	# assert ", 'A[]\nB#$_".strip_id == "_A_B_"
	# ~~~
	fun strip_id: String
	do
		var res = new Buffer
		var sp = false
		for c in chars do
			if not c.is_alphanumeric then
				sp = true
				continue
			end
			if sp then
				res.add '_'
				sp = false
			end
			res.add c
		end
		if sp then res.add '_'
		return res.to_s
	end
end
