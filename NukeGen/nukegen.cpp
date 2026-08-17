// NukeGen — the native reflection generator (replaces NukeUtils/nukegen.py, kept for old
// project CMakeLists). Scans NUKE_CLASS / NUKE_CLASS_NOCREATE + [[nuke::prop]]/[[nuke::func]]
// and emits a reflection-registration TU. Runs as a pre-build step; NO runtime dependencies
// (static CRT), so the SDK ships it as a single exe.
//
// Engine mode:  NukeGen --include <NukeEngine/include> --out <src/reflect/Reflect.gen.cpp>
// Module mode (emits an .inc the module #includes in-TU and calls from OnLoad):
//   NukeGen --include NukeScript/src --out NukeScript/src/NukeScript.gen.inc
//           --init NukeReflectInit_NukeScript --scan-cpp --no-includes
// Relative paths resolve against --root (default: the current working directory — the build
// scripts set it to the eco root, matching the python script's behavior).
#include <algorithm>
#include <charconv>
#include <filesystem>
#include <fstream>
#include <iostream>
#include <regex>
#include <set>
#include <sstream>
#include <string>
#include <vector>

namespace fs = std::filesystem;

struct FieldInfo
{
	std::string name, asset, label;
	std::string fmin, fmax;   // empty = absent
	std::string enumc, tip, widget;
	std::string ctype;        // declared C++ type text (drives --sdk accessors and --doc)
	bool hidden = false;
	bool net    = false;      // [[nuke::prop(net)]] — replicated field (NukeNet auto-collects it)
};
struct MethodInfo
{
	std::string name;
	std::string params;   // comma-joined parameter names ("atom,hitType,pos,normal,impulse")
	std::string doc;      // the contiguous // comment block right above the declaration
};
struct TypeEntry
{
	std::string cls, base, inc, cat;
	bool create = true;
	std::vector<FieldInfo> fields;
	std::vector<MethodInfo> methods;
};

static std::string Lower(std::string s)
{
	for (char& c : s) c = (char)tolower((unsigned char)c);
	return s;
}
static std::string Fwd(std::string s)
{
	for (char& c : s) if (c == '\\') c = '/';
	return s;
}

// Python str(float(x)): shortest round-trip, always with a decimal point.
static std::string FmtFloat(const std::string& raw)
{
	double v = 0.0;
	try { v = std::stod(raw); } catch (...) {}
	char buf[64];
	auto r = std::to_chars(buf, buf + sizeof(buf), v);
	std::string s(buf, r.ptr);
	if (s.find('.') == std::string::npos && s.find('e') == std::string::npos
	    && s.find("inf") == std::string::npos && s.find("nan") == std::string::npos)
		s += ".0";
	return s;
}

// Blank #define lines (+ their backslash continuations) so macro bodies quoting the reflection
// markers in comments/examples never register. Newlines stay, so match positions keep meaning.
static void BlankDefines(std::string& text)
{
	size_t lineStart = 0;
	bool blanking = false;
	while (lineStart < text.size())
	{
		size_t lineEnd = text.find('\n', lineStart);
		if (lineEnd == std::string::npos) lineEnd = text.size();
		size_t p = lineStart;
		while (p < lineEnd && (text[p] == ' ' || text[p] == '\t' || text[p] == '\r')) ++p;
		const bool isDefine = text.compare(p, 7, "#define") == 0;
		if (isDefine || blanking)
		{
			size_t contentEnd = lineEnd;
			while (contentEnd > lineStart && text[contentEnd - 1] == '\r') --contentEnd;
			blanking = contentEnd > lineStart && text[contentEnd - 1] == '\\';
			for (size_t k = lineStart; k < contentEnd; ++k) text[k] = ' ';
		}
		else blanking = false;
		lineStart = lineEnd + 1;
	}
}

// os.walk parity: a directory's files first (iteration order), then its subdirectories.
// Directories whose PATH contains "reflect" are skipped — the macro headers' comments carry
// usage examples that must not register.
static void Walk(const fs::path& dir, const std::vector<std::string>& exts, std::vector<fs::path>& out)
{
	if (Lower(Fwd(dir.string())).find("reflect") != std::string::npos) return;
	std::error_code ec;
	std::vector<fs::path> subdirs;
	for (fs::directory_iterator it(dir, ec), end; it != end && !ec; it.increment(ec))
	{
		if (it->is_directory(ec)) { subdirs.push_back(it->path()); continue; }
		const std::string name = it->path().filename().string();
		for (const std::string& e : exts)
			if (name.size() > e.size() && name.compare(name.size() - e.size(), e.size(), e) == 0)
			{ out.push_back(it->path()); break; }
	}
	for (const fs::path& d : subdirs) Walk(d, exts, out);
}

// #include path relative to whichever scan root contains the file, forward slashes.
static std::string RelInclude(const fs::path& file, const std::vector<fs::path>& roots)
{
	std::error_code ec;
	for (const fs::path& r : roots)
	{
		fs::path rel = fs::relative(file, r, ec);
		if (!ec && !rel.empty() && rel.begin()->string() != "..") return Fwd(rel.string());
	}
	return file.filename().string();
}

static std::string RegexStr(const std::smatch& m, int g) { return m[g].matched ? m[g].str() : std::string(); }

int main(int argc, char** argv)
{
	std::vector<std::string> includeArgs;
	std::string outArg, init = "NukeReflectInit", rootArg, sdkArg, docArg;
	bool scanCpp = false, noIncludes = false;
	for (int i = 1; i < argc; ++i)
	{
		const std::string a = argv[i];
		auto next = [&]() -> std::string
		{
			if (i + 1 >= argc) { std::cerr << "nukegen: missing value for " << a << "\n"; exit(2); }
			return argv[++i];
		};
		if      (a == "--include")     includeArgs.push_back(next());
		else if (a == "--out")         outArg = next();
		else if (a == "--init")        init = next();
		else if (a == "--root")        rootArg = next();
		else if (a == "--sdk")         sdkArg = next();   // typed wrapper header for OTHER modules
		else if (a == "--doc")         docArg = next();   // markdown API reference
		else if (a == "--scan-cpp")    scanCpp = true;
		else if (a == "--no-includes") noIncludes = true;
		else { std::cerr << "nukegen: unknown arg '" << a << "'\n"; return 2; }
	}
	const fs::path root = rootArg.empty() ? fs::current_path() : fs::path(rootArg);
	if (includeArgs.empty()) includeArgs.push_back((root / "NukeEngine" / "include").string());
	if (outArg.empty())      outArg = (root / "NukeEngine" / "src" / "reflect" / "Reflect.gen.cpp").string();
	std::vector<fs::path> roots;
	for (const std::string& p : includeArgs)
		roots.push_back(fs::path(p).is_absolute() ? fs::path(p) : root / p);
	const fs::path outPath = fs::path(outArg).is_absolute() ? fs::path(outArg) : root / outArg;

	// The reflection markers this engine's headers carry — kept IDENTICAL to nukegen.py.
	const std::regex kClass(R"rx(\bNUKE_CLASS(_NOCREATE)?\s*\(\s*([A-Za-z_]\w*)\s*,\s*([A-Za-z_][\w:]*)\s*(?:,\s*"([^"]*)"\s*)?\))rx");
	// \s* after ]] — C++ attributes legally sit on their own line above the declaration
	// (C++26 reflection sees them there too), so the scanner must as well.
	const std::regex kProp(R"rx(\[\[\s*nuke::prop([^\]]*)\]\]\s*([A-Za-z_][\w:*&<>, \t]*?)[ \t]+([A-Za-z_]\w*)[ \t]*(?:=|;|\{))rx");
	const std::regex kFunc(R"rx(\[\[\s*nuke::func\s*\]\]\s*(?:virtual[ \t]+|static[ \t]+)?([A-Za-z_][\w:&<>, \t*]*?)[ \t]+([A-Za-z_]\w*)[ \t]*\()rx");
	const std::regex kAsset(R"rx(asset\s*=\s*"([^"]*)")rx");
	const std::regex kLabel(R"rx(label\s*=\s*"([^"]*)")rx");
	const std::regex kMin(R"rx(\bmin\s*=\s*(-?[\d.]+))rx");
	const std::regex kMax(R"rx(\bmax\s*=\s*(-?[\d.]+))rx");
	const std::regex kEnum(R"rx(enum\s*=\s*"([^"]*)")rx");
	const std::regex kHidden(R"rx(\bhidden\b)rx");
	const std::regex kNet(R"rx(\bnet\b)rx");
	const std::regex kTip(R"rx(tip\s*=\s*"([^"]*)")rx");
	const std::regex kWidget(R"rx(widget\s*=\s*"([^"]*)")rx");

	std::vector<std::string> exts = scanCpp ? std::vector<std::string>{ ".h", ".cpp" }
	                                        : std::vector<std::string>{ ".h" };
	std::vector<fs::path> files;
	for (const fs::path& r : roots) Walk(r, exts, files);

	std::vector<TypeEntry> types;
	std::set<std::string> seenTypes;
	std::vector<TypeEntry*> order;   // stable pointers into `types` (reserve below)
	types.reserve(4096);

	for (const fs::path& path : files)
	{
		std::ifstream f(path, std::ios::binary);
		if (!f) continue;
		std::string text((std::istreambuf_iterator<char>(f)), std::istreambuf_iterator<char>());
		BlankDefines(text);

		// (position, entry*) of every class in THIS file — props/funcs bind to the nearest
		// preceding one. A type seen in an earlier file keeps that first definition.
		struct Local { size_t pos; TypeEntry* e; };
		std::vector<Local> classes;
		const std::string inc = RelInclude(path, roots);
		for (std::sregex_iterator it(text.begin(), text.end(), kClass), end; it != end; ++it)
		{
			const std::smatch& m = *it;
			const std::string cls = m[2].str();
			if (seenTypes.count(cls)) { classes.push_back({ (size_t)m.position(0), nullptr }); continue; }
			seenTypes.insert(cls);
			TypeEntry e;
			e.cls = cls; e.base = m[3].str(); e.create = !m[1].matched;
			e.inc = inc;  e.cat = RegexStr(m, 4);
			types.push_back(std::move(e));
			classes.push_back({ (size_t)m.position(0), &types.back() });
		}
		if (classes.empty()) continue;
		auto ownerOf = [&](size_t pos) -> TypeEntry*
		{
			TypeEntry* owner = nullptr;
			for (const Local& c : classes)
			{
				if (c.pos < pos) { if (c.e) owner = c.e; }
				else break;
			}
			return owner;
		};
		for (std::sregex_iterator it(text.begin(), text.end(), kProp), end; it != end; ++it)
		{
			const std::smatch& m = *it;
			TypeEntry* owner = ownerOf((size_t)m.position(0));
			if (!owner) continue;
			const std::string fname = m[3].str();
			bool dup = false;
			for (const FieldInfo& fi : owner->fields) if (fi.name == fname) { dup = true; break; }
			if (dup) continue;
			const std::string attr = m[1].str();
			FieldInfo fi;
			fi.name = fname;
			fi.ctype = m[2].str();
			while (!fi.ctype.empty() && (fi.ctype.back() == ' ' || fi.ctype.back() == '\t')) fi.ctype.pop_back();
			std::smatch am;
			if (std::regex_search(attr, am, kAsset))  fi.asset  = am[1].str();
			if (std::regex_search(attr, am, kLabel))  fi.label  = am[1].str();
			if (std::regex_search(attr, am, kMin))    fi.fmin   = am[1].str();
			if (std::regex_search(attr, am, kMax))    fi.fmax   = am[1].str();
			if (std::regex_search(attr, am, kEnum))   fi.enumc  = am[1].str();
			if (std::regex_search(attr, am, kTip))    fi.tip    = am[1].str();
			if (std::regex_search(attr, am, kWidget)) fi.widget = am[1].str();
			fi.hidden = std::regex_search(attr, am, kHidden);
			fi.net    = std::regex_search(attr, am, kNet);
			owner->fields.push_back(std::move(fi));
		}
		for (std::sregex_iterator it(text.begin(), text.end(), kFunc), end; it != end; ++it)
		{
			const std::smatch& m = *it;
			TypeEntry* owner = ownerOf((size_t)m.position(0));
			if (!owner) continue;
			const std::string mname = m[2].str();
			bool dup = false;
			for (const MethodInfo& e : owner->methods) if (e.name == mname) { dup = true; break; }
			if (dup) continue;
			MethodInfo mi; mi.name = mname;
			// Parameter NAMES: the match stops right after '(' — scan the balanced (...) and take
			// the last identifier of each top-level comma piece (defaults stripped at '=').
			{
				size_t p = (size_t)m.position(0) + (size_t)m.length(0);
				int depth = 1; std::string args;
				while (p < text.size() && depth > 0)
				{
					const char c = text[p++];
					if (c == '(') ++depth;
					else if (c == ')') { if (--depth == 0) break; }
					if (depth > 0) args += c;
				}
				int ad = 0; std::vector<std::string> parts; std::string cur;
				for (char c : args)
				{
					if (c == '<' || c == '(') ++ad;
					else if (c == '>' || c == ')') --ad;
					if (c == ',' && ad == 0) { parts.push_back(cur); cur.clear(); }
					else cur += c;
				}
				if (!cur.empty()) parts.push_back(cur);
				for (std::string part : parts)
				{
					const size_t eq = part.find('=');
					if (eq != std::string::npos) part = part.substr(0, eq);
					size_t e = part.size();
					while (e > 0 && isspace((unsigned char)part[e - 1])) --e;
					size_t s = e;
					while (s > 0 && (isalnum((unsigned char)part[s - 1]) || part[s - 1] == '_')) --s;
					const std::string pname = part.substr(s, e - s);
					if (pname.empty() || pname == "void") continue;
					if (!mi.params.empty()) mi.params += ",";
					mi.params += pname;
				}
			}
			// Doc = the contiguous // comment block ending on the line above the attribute.
			{
				size_t ls = text.rfind('\n', (size_t)m.position(0));
				std::vector<std::string> cl;
				while (ls != std::string::npos && ls > 0)
				{
					const size_t prev = text.rfind('\n', ls - 1);
					const size_t b0 = (prev == std::string::npos) ? 0 : prev + 1;
					std::string line = text.substr(b0, ls - b0);
					size_t b = 0;
					while (b < line.size() && (line[b] == ' ' || line[b] == '\t')) ++b;
					if (line.compare(b, 2, "//") != 0) break;
					b += 2;
					while (b < line.size() && line[b] == ' ') ++b;
					size_t le = line.size();
					while (le > b && (line[le - 1] == '\r' || line[le - 1] == ' ')) --le;
					cl.push_back(line.substr(b, le - b));
					if (prev == std::string::npos) break;
					ls = prev;
				}
				for (size_t k = cl.size(); k-- > 0; )
				{
					if (!mi.doc.empty()) mi.doc += ' ';
					mi.doc += cl[k];
				}
			}
			owner->methods.push_back(std::move(mi));
		}
	}

	// de-dupe includes, keep order
	std::vector<std::string> incs;
	{
		std::set<std::string> seen;
		for (const TypeEntry& t : types)
			if (seen.insert(t.inc).second) incs.push_back(t.inc);
	}

	auto escape = [](const std::string& s)
	{
		std::string o;
		for (char c : s)
		{
			if (c == '\\') o += "\\\\";
			else if (c == '"') o += "\\\"";
			else o += c;
		}
		return o;
	};

	std::vector<std::string> lines;
	lines.push_back("// AUTO-GENERATED by nukegen — DO NOT EDIT.");
	if (!noIncludes)
	{
		lines.push_back("#include \"reflect/Reflect.h\"");
		for (const std::string& inc : incs) lines.push_back("#include \"" + inc + "\"");
		lines.push_back("");
	}
	else
		lines.push_back("// #included IN-TU after the module's component definitions (no headers here).");
	lines.push_back("namespace nuke {");
	if (noIncludes)
	{
		lines.push_back("// Registers this MODULE's reflected components into the engine's shared registry.");
		lines.push_back("// Call once from the module's NUKEModule::OnLoad (before any world deserializes).");
	}
	else
	{
		lines.push_back("// Called once from World's constructor. Must be an EXTERNAL function called from a");
		lines.push_back("// linked TU, otherwise the linker discards this .obj (and its registration) from");
		lines.push_back("// the static lib (nothing else references it).");
	}
	lines.push_back("bool " + init + "() {");
	lines.push_back("\tstatic bool _done = false;");
	lines.push_back("\tif (_done) return true;");
	lines.push_back("\t_done = true;");
	for (const TypeEntry& t : types)
	{
		lines.push_back("\t{");
		lines.push_back("\t\tTypeInfo& t = TypeOf<" + t.cls + ">();");
		lines.push_back("\t\tt.base = \"" + t.base + "\";");
		if (!t.cat.empty())
			lines.push_back("\t\tt.category = \"" + t.cat + "\";");
		for (const FieldInfo& fi : t.fields)
		{
			const std::string amp = "&" + t.cls + "::" + fi.name;
			if (!fi.enumc.empty())
			{
				const std::string mn = FmtFloat(fi.fmin.empty() ? "0" : fi.fmin);
				const std::string mx = FmtFloat(fi.fmax.empty() ? "0" : fi.fmax);
				lines.push_back("\t\tt.fields.push_back(MakeField(\"" + fi.name + "\", " + amp + ", \"" + fi.asset
				                + "\", \"" + fi.label + "\", " + mn + "f, " + mx + "f, \"" + fi.enumc + "\"));");
			}
			else if (!fi.fmin.empty() && !fi.fmax.empty())
				lines.push_back("\t\tt.fields.push_back(MakeField(\"" + fi.name + "\", " + amp + ", \"" + fi.asset
				                + "\", \"" + fi.label + "\", " + FmtFloat(fi.fmin) + "f, " + FmtFloat(fi.fmax) + "f));");
			else if (!fi.label.empty())
				lines.push_back("\t\tt.fields.push_back(MakeField(\"" + fi.name + "\", " + amp + ", \"" + fi.asset
				                + "\", \"" + fi.label + "\"));");
			else if (!fi.asset.empty())
				lines.push_back("\t\tt.fields.push_back(MakeField(\"" + fi.name + "\", " + amp + ", \"" + fi.asset + "\"));");
			else
				lines.push_back("\t\tt.fields.push_back(MakeField(\"" + fi.name + "\", " + amp + "));");
			if (fi.hidden)
				lines.push_back("\t\tt.fields.back().hidden = true;");
			if (fi.net)
				lines.push_back("\t\tt.fields.back().net = true;");
			if (!fi.tip.empty())
				lines.push_back("\t\tt.fields.back().tip = \"" + escape(fi.tip) + "\";");
			if (!fi.widget.empty())
				lines.push_back("\t\tt.fields.back().widget = \"" + fi.widget + "\";");
		}
		for (const MethodInfo& mi : t.methods)
		{
			lines.push_back("\t\tt.methods.push_back(MakeMethod(\"" + mi.name + "\", &" + t.cls + "::" + mi.name + "));");
			if (!mi.doc.empty() || !mi.params.empty())
				lines.push_back("\t\tReflect_SetMethodDoc(\"" + t.cls + "\", \"" + mi.name + "\", \""
				                + escape(mi.doc) + "\", \"" + mi.params + "\");");
		}
		if (t.create)
			lines.push_back("\t\tt.create = []() -> void* { return new " + t.cls + "(); };");
		lines.push_back("\t}");
	}
	lines.push_back("\treturn true;");
	lines.push_back("}");
	lines.push_back("}  // namespace nuke");
	lines.push_back("");

	// "\n"-join with the trailing empty entry = every line newline-terminated, none after the last.
	std::string content;
	for (const std::string& l : lines) { content += l; content += '\n'; }
	if (!content.empty()) content.pop_back();

	// Write-if-changed, TEXT mode both ways (CRLF on Windows, like the python tool).
	auto writeIfChanged = [](const fs::path& path, const std::string& body) -> int
	{
		std::error_code wec;
		fs::create_directories(path.parent_path(), wec);
		std::string old;
		bool hadOld = false;
		{
			std::ifstream in(path);   // text mode: \r\n reads back as \n
			if (in) { old.assign((std::istreambuf_iterator<char>(in)), std::istreambuf_iterator<char>()); hadOld = true; }
		}
		if (hadOld && old == body) return 0;
		std::ofstream out(path);      // text mode: \n writes as \r\n
		if (!out) { std::cerr << "nukegen: cannot write " << path.string() << "\n"; return -1; }
		out << body;
		return 1;
	};
	const int wrote = writeIfChanged(outPath, content);
	if (wrote < 0) return 1;
	if (wrote > 0) std::cout << "nukegen: wrote " << outPath.string() << " (" << types.size() << " types)\n";
	else           std::cout << "nukegen: up to date (" << types.size() << " types)\n";

	// The declared C++ prop type -> the ReflectValue field carrying it. Everything else (lists,
	// module-private structs) stays reachable through the generic reflection calls.
	enum Kind { kNone, kBool, kInt, kFloat, kDouble, kString, kVecN, kColor, kAtom };
	struct TInfo { Kind kind; int comps; };
	auto typeOf = [](std::string t) -> TInfo
	{
		std::string ns;   // normalized: no spaces ("Atom *" == "Atom*")
		for (char c : t) if (c != ' ' && c != '\t') ns += c;
		if (ns == "bool")   return { kBool, 0 };
		if (ns == "int" || ns == "long" || ns == "unsignedlong" || ns == "longlong") return { kInt, 0 };
		if (ns == "float")  return { kFloat, 0 };
		if (ns == "double") return { kDouble, 0 };
		if (ns == "std::string" || ns == "string") return { kString, 0 };
		if (ns == "Vector2") return { kVecN, 2 };
		if (ns == "Vector3") return { kVecN, 3 };
		if (ns == "Vector4" || ns == "Quaternion") return { kVecN, 4 };
		if (ns == "Color")  return { kColor, 4 };
		if (ns == "Atom*")  return { kAtom, 0 };
		return { kNone, 0 };
	};

	// ---- --sdk: typed accessors over the reflection registry --------------------------------
	// The point: another module (or a mod's game code) drives THIS module's components with
	// real types and zero linking — a missing/disabled module yields invalid refs, not link
	// errors. Only creatable components get a Ref; facades/statics have no instances to wrap.
	if (!sdkArg.empty())
	{
		const fs::path sdkPath = fs::path(sdkArg).is_absolute() ? fs::path(sdkArg) : root / sdkArg;
		std::string o;
		o += "// AUTO-GENERATED by nukegen --sdk — DO NOT EDIT.\n";
		o += "// Typed accessors over the reflection registry for the components " + init + " registers.\n";
		o += "// Reach this module's components from other modules or game code WITHOUT linking it:\n";
		o += "// everything resolves through ReflectBind at runtime, so a missing or disabled module\n";
		o += "// yields invalid refs instead of link errors. [[nuke::func]] methods are reachable\n";
		o += "// through Reflect_FindMethod + Reflect_Invoke; list props through Reflect_Get/SetListJson.\n";
		o += "#pragma once\n";
		o += "#include <reflect/Reflect.h>\n#include <reflect/ReflectBind.h>\n";
		o += "#include <API/Model/Atom.h>\n#include <API/Model/Component.h>\n";
		o += "#include <API/Model/Vector.h>\n#include <API/Model/Color.h>\n\n";
		o += "namespace nuke { namespace sdk {\n";
		for (const TypeEntry& t : types)
		{
			if (!t.create) continue;
			const std::string R = t.cls + "Ref";
			o += "\nstruct " + R + "\n{\n";
			o += "\tComponent* c = nullptr;\n";
			o += "\t" + R + "() = default;\n";
			o += "\texplicit " + R + "(Atom* a) : c(a ? Reflect_FindComponent(a, \"" + t.cls + "\") : nullptr) {}\n";
			o += "\tstatic " + R + " Add(Atom* a) { " + R + " r; if (a) r.c = Reflect_AddComponent(a, \"" + t.cls + "\"); return r; }\n";
			o += "\tbool valid() const { return c != nullptr; }\n";
			o += "\tbool enabled() const { return c && c->enabled; }\n";
			o += "\tvoid enabled(bool v) { if (c) c->enabled = v; }\n";
			for (const FieldInfo& fi : t.fields)
			{
				const TInfo ti = typeOf(fi.ctype);
				const std::string& n = fi.name;
				switch (ti.kind)
				{
				case kBool:
					o += "\tbool " + n + "() const { return Get(\"" + n + "\").b; }\n";
					o += "\tvoid " + n + "(bool x) { ReflectValue v; v.type = FT::Bool; v.b = x; Set(\"" + n + "\", v); }\n";
					break;
				case kInt:
					o += "\t" + fi.ctype + " " + n + "() const { return (" + fi.ctype + ")Get(\"" + n + "\").num; }\n";
					o += "\tvoid " + n + "(" + fi.ctype + " x) { ReflectValue v; v.type = FT::Int; v.num = (double)x; Set(\"" + n + "\", v); }\n";
					break;
				case kFloat:
					o += "\tfloat " + n + "() const { return (float)Get(\"" + n + "\").num; }\n";
					o += "\tvoid " + n + "(float x) { ReflectValue v; v.type = FT::Float; v.num = x; Set(\"" + n + "\", v); }\n";
					break;
				case kDouble:
					o += "\tdouble " + n + "() const { return Get(\"" + n + "\").num; }\n";
					o += "\tvoid " + n + "(double x) { ReflectValue v; v.type = FT::Double; v.num = x; Set(\"" + n + "\", v); }\n";
					break;
				case kString:
					o += "\tstd::string " + n + "() const { return Get(\"" + n + "\").str; }\n";
					o += "\tvoid " + n + "(const std::string& x) { ReflectValue v; v.type = FT::String; v.str = x; Set(\"" + n + "\", v); }\n";
					break;
				case kVecN:
				{
					static const char* mem = "xyzw";
					const char* ft = ti.comps == 2 ? "Vec2" : ti.comps == 3 ? "Vec3"
					               : fi.ctype == "Quaternion" ? "Quat" : "Vec4";
					o += "\t" + fi.ctype + " " + n + "() const { ReflectValue rv = Get(\"" + n + "\"); " + fi.ctype + " r;";
					for (int k = 0; k < ti.comps; ++k) o += std::string(" r.") + mem[k] + " = rv.v[" + std::to_string(k) + "];";
					o += " return r; }\n";
					o += "\tvoid " + n + "(const " + fi.ctype + "& x) { ReflectValue v; v.type = FT::" + ft + ";";
					for (int k = 0; k < ti.comps; ++k) o += std::string(" v.v[") + std::to_string(k) + "] = x." + mem[k] + ";";
					o += " Set(\"" + n + "\", v); }\n";
					break;
				}
				case kColor:
				{
					static const char* mem[4] = { "r", "g", "b", "a" };
					o += "\tColor " + n + "() const { ReflectValue rv = Get(\"" + n + "\"); Color r;";
					for (int k = 0; k < 4; ++k) o += std::string(" r.") + mem[k] + " = rv.v[" + std::to_string(k) + "];";
					o += " return r; }\n";
					o += "\tvoid " + n + "(const Color& x) { ReflectValue v; v.type = FT::Color;";
					for (int k = 0; k < 4; ++k) o += std::string(" v.v[") + std::to_string(k) + "] = x." + mem[k] + ";";
					o += " Set(\"" + n + "\", v); }\n";
					break;
				}
				case kAtom:
					o += "\tAtom* " + n + "() const { return Reflect_AtomById(Get(\"" + n + "\").atom); }\n";
					o += "\tvoid " + n + "(Atom* x) { ReflectValue v; v.type = FT::AtomRef; v.atom = Reflect_AtomId(x); Set(\"" + n + "\", v); }\n";
					break;
				default:
					o += "\t// " + n + " (" + fi.ctype + "): list/custom type — use Reflect_Get/SetListJson or Reflect_Get/SetField.\n";
					break;
				}
			}
			o += "private:\n";
			o += "\tReflectValue Get(const char* n) const\n\t{\n";
			o += "\t\tconst Field* f = c ? Reflect_FindField(Registry_Find(\"" + t.cls + "\"), n) : nullptr;\n";
			o += "\t\treturn f ? Reflect_GetField(c, *f) : ReflectValue();\n\t}\n";
			o += "\tvoid Set(const char* n, const ReflectValue& v)\n\t{\n";
			o += "\t\tconst Field* f = c ? Reflect_FindField(Registry_Find(\"" + t.cls + "\"), n) : nullptr;\n";
			o += "\t\tif (f) Reflect_SetField(c, *f, v);\n\t}\n";
			o += "};\n";
		}
		o += "\n}}  // namespace nuke::sdk\n";
		if (writeIfChanged(sdkPath, o) > 0) std::cout << "nukegen: sdk -> " << sdkPath.string() << "\n";
	}

	// ---- --doc: markdown API reference -------------------------------------------------------
	// The tips/labels/ranges already written for the inspector ARE the documentation; this just
	// collects them where a modder can read them without the editor.
	if (!docArg.empty())
	{
		const fs::path docPath = fs::path(docArg).is_absolute() ? fs::path(docArg) : root / docArg;
		std::string title = init;
		if (title.rfind("NukeReflectInit_", 0) == 0) title = title.substr(16);
		else if (title == "NukeReflectInit") title = "NukeEngine";
		std::string o;
		o += "# " + title + " — reflected API\n\n";
		o += "_AUTO-GENERATED by nukegen --doc — edit the `[[nuke::prop]]` attributes, not this file._\n";
		for (const TypeEntry& t : types)
		{
			o += "\n## " + t.cls + "\n\n";
			o += "Base: `" + t.base + "`";
			if (!t.cat.empty()) o += " · Category: " + t.cat;
			o += t.create ? " · Creatable component\n" : " · Static/facade (no instances)\n";
			if (!t.fields.empty())
			{
				o += "\n| Prop | Type | Label | Details |\n|---|---|---|---|\n";
				for (const FieldInfo& fi : t.fields)
				{
					std::string det;
					auto add = [&](const std::string& s) { if (!s.empty()) { if (!det.empty()) det += "; "; det += s; } };
					if (!fi.fmin.empty() || !fi.fmax.empty()) add("range " + fi.fmin + ".." + fi.fmax);
					if (!fi.enumc.empty())  add("enum: " + fi.enumc);
					if (!fi.asset.empty())  add("asset: " + fi.asset);
					if (fi.hidden)          add("hidden");
					if (!fi.widget.empty()) add("widget: " + fi.widget);
					if (!fi.tip.empty())    add(fi.tip);
					o += "| " + fi.name + " | `" + fi.ctype + "` | " + fi.label + " | " + det + " |\n";
				}
			}
			if (!t.methods.empty())
			{
				o += "\nMethods:\n\n";
				for (const MethodInfo& mi : t.methods)
				{
					std::string sig;
					for (char c : mi.params) { sig += c; if (c == ',') sig += ' '; }
					o += "- `" + mi.name + "(" + sig + ")`";
					if (!mi.doc.empty()) o += " — " + mi.doc;
					o += "\n";
				}
			}
		}
		if (writeIfChanged(docPath, o) > 0) std::cout << "nukegen: doc -> " << docPath.string() << "\n";
	}
	return 0;
}
