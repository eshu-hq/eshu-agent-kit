# OpenCode backend for install.sh installs. Sourced by install.sh;
# extracted to keep the entrypoint under the 500-line cap, like install-aliases.sh.
# shellcheck shell=bash

# Shared JSONC reader for the OpenCode config: JSON first, then a tolerant
# pass that strips // and /* comments (string-aware) and trailing commas.
# Modes: model -> print the top-level model; get <role> -> print that agent's
# configured model; merge <main> <role> <model>... -> write the merged file.
OC_PY='
import json, sys

def strip_comments(text):
	out, i, n, in_str = [], 0, len(text), False
	while i < n:
		c = text[i]
		if in_str:
			out.append(c)
			if c == "\\" and i + 1 < n:
				out.append(text[i + 1]); i += 2; continue
			if c == "\"":
				in_str = False
			i += 1
		elif c == "\"":
			in_str = True; out.append(c); i += 1
		elif text.startswith("//", i):
			while i < n and text[i] != "\n":
				i += 1
		elif text.startswith("/*", i):
			j = text.find("*/", i + 2)
			i = n if j < 0 else j + 2
		else:
			out.append(c); i += 1
	return "".join(out)

def drop_trailing_commas(text):
	# Single string-aware pass: a comma whose next non-space char is } or ]
	# is dropped; commas inside string values are copied verbatim.
	out, i, n, in_str = [], 0, len(text), False
	while i < n:
		c = text[i]
		if in_str:
			out.append(c)
			if c == "\\" and i + 1 < n:
				out.append(text[i + 1]); i += 2; continue
			if c == "\"":
				in_str = False
			i += 1
		elif c == "\"":
			in_str = True; out.append(c); i += 1
		elif c == ",":
			j = i + 1
			while j < n and text[j] in " \t\r\n":
				j += 1
			if j < n and text[j] in "}]":
				i += 1
			else:
				out.append(c); i += 1
		else:
			out.append(c); i += 1
	return "".join(out)

def load_jsonc(text):
	try:
		return json.loads(text)
	except Exception:
		pass
	return json.loads(drop_trailing_commas(strip_comments(text)))

def read_config(path):
	raw = ""
	try:
		raw = open(path).read()
	except FileNotFoundError:
		pass
	if not raw.strip():
		return {}
	data = load_jsonc(raw)
	if not isinstance(data, dict):
		raise ValueError("top-level JSON value is not an object")
	return data

path, mode, *rest = sys.argv[1:]
try:
	data = read_config(path)
except Exception as exc:
	print("opencode config not mergeable: %s" % exc, file=sys.stderr)
	sys.exit(1)
if mode == "model":
	m = data.get("model", "")
	print(m if isinstance(m, str) else "")
elif mode == "get":
	for k in ("agents", "agent"):
		sec = data.get(k)
		if isinstance(sec, dict):
			entry = sec.get(rest[0])
			if isinstance(entry, dict) and isinstance(entry.get("model"), str):
				print(entry["model"])
				break
else:
	main = rest[0] if rest else ""
	pairs = rest[1:] if rest else []
	if main:
		data["model"] = main
	keys = [k for k in ("agents", "agent") if isinstance(data.get(k), dict)]
	if not keys:
		keys = ["agents"]
	for k in keys:
		if not isinstance(data.get(k), dict):
			data[k] = {}
	for i in range(0, len(pairs), 2):
		role, model = pairs[i], pairs[i + 1]
		for k in keys:
			entry = data[k].get(role)
			data[k][role] = dict(entry, model=model) if isinstance(entry, dict) else {"model": model}
	open(path, "w").write(json.dumps(data, indent=2) + "\n")
'

# Merge per-agent model choices (and the optional main model) into the global
# OpenCode config so they win over any stale frontmatter overrides.
merge_opencode_config() {
	local config="$HOME/.config/opencode/opencode.jsonc"
	python3 - "$config" merge "$@" <<<"$OC_PY"
}

# Current value for one prompt default, through the same tolerant parser.
opencode_config_value() { # $1 config path, $2 mode, [$3 role]
	if [ "$2" = get ]; then
		python3 - "$1" get "$3" <<<"$OC_PY" 2>/dev/null || true
	else
		python3 - "$1" model <<<"$OC_PY" 2>/dev/null || true
	fi
}

# Global opencode agents: ask a model per role, then sync the config section.
install_opencode_agents() {
	local config="$HOME/.config/opencode/opencode.jsonc"
	local current_main="" main f role model cfg
	current_main="$(opencode_config_value "$config" model)"
	main="$(ask_model "the main model" "${current_main:-}")"
	local -a pairs=()
	local file
	for file in "$KIT_DIR"/.opencode/agent/*.md; do
		[ -f "$file" ] || continue
		f="$(basename "$file" .md)"
		model="$(agent_model_default opencode "$f")"
		cfg="$(opencode_config_value "$config" get "$f")"
		[ -n "$cfg" ] && model="$cfg"
		model="$(ask_model "$f" "$model")"
		write_agent_file "$file" "$HOME/.config/opencode/agents" "$model"
		pairs+=("$f" "$model")
	done
	merge_opencode_config "$main" "${pairs[@]}"
	prune_dir "$HOME/.config/opencode/agents" "$KIT_DIR/.opencode/agent/*.md"
	echo "installed kit agents for opencode (model choices recorded in $config)"
}
