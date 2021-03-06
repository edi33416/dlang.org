#!/usr/bin/env rdmd
/**
A wrapper around DDoc to allow custom extensions

Copyright: D Language Foundation 2018

License:   $(WEB boost.org/LICENSE_1_0.txt, Boost License 1.0).

Example usage:

---
./ddoc --compiler=<path-to-dmd> --output=out.html myfile.dd
---

Author: Sebastian Wilzbach
*/
import std.algorithm, std.array, std.ascii, std.conv, std.file, std.functional,
        std.meta, std.path, std.range, std.string, std.typecons;
import std.stdio : writeln, writefln;

struct Config
{
    string dmdBinPath = "dmd";
    string outputFile;
}
Config config;

int main(string[] args)
{
    import std.getopt;
    auto helpInformation = getopt(
        args,
        "compiler", "Compiler to use", &config.dmdBinPath,
        "o|output", "Output file", &config.outputFile,
    );

    assert(config.outputFile, "An output file is required.");
    assert(args.length > 1, "An input file is required.");

    if (helpInformation.helpWanted)
    {
`DDoc wrapper
./ddoc <file>...
`.defaultGetoptPrinter(helpInformation.options);
        return 1;
    }

    import std.file : readText;
    auto text = args[$ - 1].readText;

    // transform and extend the ddoc page
    text = genHeader(text);

    return compile(text, args[1 .. $ - 1]);
}

auto compile(R)(R buffer, string[] arguments)
{
    import std.process : pipeProcess, Redirect, wait;
    auto args = [config.dmdBinPath, "-c", "-Df"~config.outputFile, "-o-"] ~ arguments;
    args ~= "-";
    auto pipes = pipeProcess(args, Redirect.stdin);
    pipes.stdin.write(buffer);
    pipes.stdin.close;
    return wait(pipes.pid);
}

// replaces the content of a DDoc macro call
auto updateDdocTag(string fileText, string ddocKey, string newContent)
{
    auto pos = fileText.representation.countUntil(ddocKey);
    if (pos < 0)
        return fileText;
    const ddocStartLength = ddocKey.representation.until('(', No.openRight).count;
    auto len = fileText[pos .. $].representation.drop(ddocStartLength).untilClosingParentheses.walkLength;
    return fileText.replace(fileText[pos .. pos + len + ddocStartLength + 1], newContent);
}

// a range until the next ')', nested () are ignored
auto untilClosingParentheses(R)(R rs)
{
    return rs.cumulativeFold!((count, r){
        switch(r)
        {
            case '(':
                count++;
                break;
            case ')':
                count--;
                break;
            default:
        }
        return count;
    })(1).zip(rs).until!(e => e[0] == 0).map!(e => e[1]);
}

unittest
{
    import std.algorithm.comparison : equal;
    assert("aa $(foo $(bar)foobar)".untilClosingParentheses.equal("aa $(foo $(bar)foobar)"));
    assert("$(FOO a, b, $(ARGS e, f)))".untilClosingParentheses.equal("$(FOO a, b, $(ARGS e, f))"));
}

// parse the ddoc file for H2 and H3 items
// H3 items are listed as subitems
auto parseToc(string text)
{
    alias TocEntry = Tuple!(string, "id", string, "name");
    alias TocTopEntry = Tuple!(TocEntry, "main", TocEntry[], "children");
    TocTopEntry[] toc;

    bool isH2 = true;
    void append(string id, string name)
    {
        auto entry = TocEntry(id, name);
        if (isH2)
            toc ~= TocTopEntry(entry, null);
        else
            toc.back.children ~= entry;
    }
    while (!text.empty)
    {
        enum needles = AliasSeq!("$(H2 ", "$(SECTION2 ", "$(H3", "$(SECTION3");
        auto res = text.find(needles);
        if (res[0].empty)
            break;

        isH2 = res[1] <= 2;
        text = res[0].drop(needles.only[res[1] - 1].length);
        text.skipOver!isWhite;

        enum gname = "$(GNAME ";
        enum lNameNeedles = AliasSeq!("$(LNAME2", "$(LEGACY_LNAME2");
        if (text.startsWith(gname))
        {
            auto name = text.drop(gname.length).untilClosingParentheses.to!string.strip;
            append(name, name);
        }
        else if (auto idx = text.startsWith(lNameNeedles))
        {
            auto arr = text.drop(lNameNeedles.only[idx - 1].length).splitter(",");
            if (idx == 2)
                arr.popFront;
            append(arr.front.strip, arr.dropOne.joiner(",").untilClosingParentheses.to!string.strip);
        }
    }
    return toc;
}

// Ddoc splits arguments by commas
auto escapeDdoc(string s)
{
    return s.replace(",", "$(COMMA)");
}

// generated a SPEC_HEADERNAV_TOC Ddoc macro with the parsed H2/H3 entries
auto genHeader(string fileText)
{
    enum ddocKey = "$(SPEC_HEADERNAV_TOC";
    auto newContent = ddocKey ~ "\n";
    enum indent = "    ";
    foreach (entry; fileText.parseToc)
    {
        if (entry.children)
        {
            newContent ~= "%s$(SPEC_HEADERNAV_SUBITEMS %s, %s,\n".format(indent, entry.main.id, entry.main.name.escapeDdoc);
            foreach (child; entry.children)
                newContent ~= "%s$(SPEC_HEADERNAV_ITEM %s, %s)\n".format(indent.repeat(2).joiner, child.id, child.name.escapeDdoc);
            newContent ~= indent;
            newContent ~= ")\n";
        }
        else
        {
            newContent ~= "%s$(SPEC_HEADERNAV_ITEM %s, %s)\n".format(indent, entry.main.id, entry.main.name.escapeDdoc);
        }
    }
    newContent ~= ")";
    return updateDdocTag(fileText, ddocKey, newContent);
}

