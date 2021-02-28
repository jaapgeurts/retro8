import std.stdio;
import std.file;
import std.string;
import std.conv;
import std.variant;
import std.random : uniform;
import std.range;
import std.array;
import std.algorithm;
import std.algorithm.searching : count;
import core.stdc.stdlib : exit;

import pegged.grammar;

mixin(grammar(`
Retro8:
    Start        <  Unit Import* Sequence Eof
    Unit         <  "unit" Identifier ';'?
    Import       <  "import" Identifier ';'?

    Identifier   <~ [a-zA-Z_]([a-zA-Z_]/[0-9])*

    Sequence     <  ConstList? VarList? ExternList? Function*

    ConstList    <  "constants" '{' ConstDecl* '}' 
    ConstDecl    <  Identifier '=' Literal ';'?  

    VarList      <  "variables" '{' VarDecl* '}' 
    VarDecl      <  SimpleDecl ';'?  
    #              / arraydecl ';'?

    ExternList   < "extern"  '{'  Prototype* '}' 

    SimpleDecl   <  Identifier ':' Type TypeSuffix? (':=' Literal)?
    Type         <  "ubyte"
                  / "byte"
                  / "uword"
                  / "word"
                  / "bool"
    TypeSuffix   < '[' (DecLit/HexLit)? ']'

    #RegType      < Register '!' Type # add this

    Literal      <-  HexLit /  BinLit / OctLit / DecLit / BoolLit / CharLit / StringLit
    DecLit       <~ [0-9]+
    BinLit       <~ "0b" [0-1]+
    OctLit       <~ "0o" [0-7]+
    HexLit       <~ "0x" ( [0-9A-Fa-f] [0-9A-Fa-f] )+
    BoolLit      <- "true" / "false" 
    CharLit      <~ :quote (!quote ((backslash [bnrt]) / .)) :quote
    StringLit    <- :doublequote ~((!(doublequote / eol)  .)*) :doublequote

    Function     <  "function"  Signature  StatementBlock 
    Prototype    <  "function"  ProtoSignature  

    Signature    <  Identifier Parameters (':' Register '!' Type )?
    Parameters   < '(' ParamList? ')'
    ParamList    <   Identifier ':' Register '!' Type TypeSuffix? (',' ParamList )?

    ProtoSignature    <  Identifier ProtoParameters (':' Register '!' Type )?
    ProtoParameters   < '(' ParamTypeList? ')'
    ParamTypeList     < Register '!' Type TypeSuffix? (',' ParamTypeList )?

    LocalVarDecl     <  Identifier ':' Register '!' Type TypeSuffix?

    StatementBlock   < '{' LocalVarDecl*  StatementList* '}' 
    StatementList    < Statement  ';'?  (StatementList)*

    Statement       < UnaryExpression
                     / AssignmentStmt 
                     / ReturnStmt
                     / IfStmt
                     / LoopStmt
                     / RepeatUntilStmt
                     / BreakStmt
                     / WhileStmt
                     / FuncCall
                     / AsmStmt

    AssignmentStmt   <  (Identifier / IndirectAccess / Port) ':=' Expression
    ReturnStmt       < "return" Expression?
    BreakStmt        < "break"
    
    LoopStmt         < "loop" StatementBlock

    RepeatUntilStmt  < "repeat" StatementBlock "until" Expression

 
    IfStmt           < IfBlock ElIfBlock* ElseBlock?
    IfBlock          < "if" Expression StatementBlock 
    ElIfBlock        < "elif" Expression StatementBlock
    ElseBlock        < "else" StatementBlock
    WhileStmt        < "while" Expression StatementBlock

    UnaryExpression  < Identifier PostfixOp
    PostfixOp        <- '++' / '--'

    Expression        < SimpleExpression (RelationOp SimpleExpression)?
    SimpleExpression <  ( '+' / '-' )? Term (AddOp Term)*
    Term             <  Factor (MulOp Factor)*

    Factor        <  Literal
                    / FuncCall
                    / Port
                    / Identifier
                    / IndirectAccess
                    / '(' Expression ')'
                    / "null"

    IndirectAccess   < '[' (Identifier / Literal) RefAdd? ']'

    RefAdd          < ('+' Literal)

    Port             < '#' (Identifier /Literal)
    
    Register         <- "AF" / "BC" / "DE" / "HL" / "IX" / "IY" / [ABCDEFHL]
    
    ExprList      <  Expression (',' Expression)*

    RelationOp    <  '<=' / '>=' / '!=' / '=' / '<' / '>' 
    AddOp         <   "or" / '+' / '-'
    MulOp         <  '%' / '*' / '/' / "and"
                
    FuncCall     <  Identifier '(' ArgList* ')'

    AsmStmt      <  "asm" '{' RawAsm '}'
    RawAsm       <- ~(!'}' .)*

    ArgList      <  Expression (',' Expression )*

    Comment      <- LineComment / BlockComment
    LineComment  <~ "//" ( !eol . )* eol
    BlockComment <~ "/*" (!"*/" .)* "*/"

    Spacing      <: ( WhiteSpace / Comment )*

    WhiteSpace   <- Eol / ' ' / '\t' 

    Eol          <- "\r\n" / '\n' / '\r'
    Eof          <- !.

`));

enum Register {
    AF,
    BC,
    DE,
    HL,
    IX,
    IY,
    A,
    B,
    C,
    D,
    E,
    F,
    H,
    L
}

enum Kind {
    None,
    Constant,
    Variable,
    Register,
    Function
}

enum Type {
    None,
    Bool,
    Byte,
    Word,
}

struct Param {
    string register; // should use enum here
    Type type;
    bool isPointer;
}

class Symbol {
    Kind kind = Kind.None;
    string name;
    Type type;
    bool isSigned;
    bool isPointer;
    bool isString; // for internal use only
    string value;
    string code;
    string register;
    Param[] funcargs;
    int count = 1;

    public this(Kind kind, string name, Type type, string register, bool signed,
            bool isPointer, bool isString, string value, string code, int count) {
        this.kind = kind;
        this.name = name;
        this.type = type;
        this.register = register;
        isSigned = signed;
        this.isPointer = isPointer;
        this.isString = isString;
        this.value = value;
        this.register = register;
        this.count = count;
    }
}

Symbol[string] symboltable;

class LocalScope {
    Symbol[string] symbols;
}

LocalScope[] localsymbolstack;

string genIdentifier() {
    char[] rnd = generate!(() => uniform(0, 26) + 'a').takeExactly(10).map!(v => cast(char) v)
        .array;
    return rnd.idup;
}

int linecount = 0;

string filename;

void main(string[] args) {

    if (args.length != 2) {
        stderr.writefln("USAGE %s <filename>", args[0]);
    }

    filename = args[1];
    string input = readText(filename);

    // Parsing at compile-time:
    ParseTree parseTree1 = Retro8(input);

    //  parseTree1 = simplifyTree(parseTree1);

    // pragma(msg, parseTree1.matches);
    stderr.writeln(parseTree1);

    // TODO: make it two pass.

    emitAssembly(parseTree1, 0);

    emitConst();

    emitData();

}

void emitConst() {
    writeln("; List of constants");
    foreach (v; symboltable.values.filter!(a => !a.isString
            && (a.type == Type.Byte || a.type == Type.Word) && a.kind == Kind.Constant)) {
        // todo check if there is an array.
        string tabs = generate!(() => '\t').takeExactly((23 - v.name.length) / 8 + 1).array;
        writeln(v.name, "\tequ\t", v.value, "\t\t; ", v.code);
    }
}

string toAsmStr(string src) {
    string dst = "";
    int count = 0;
    bool instring = false;

    int i = 0;
    while (i < src.length) {
        char c = src[i];
        if (c != '\\') { // normal char
            if (!instring) {
                dst ~= "\"";
                instring = true;
            }
            dst ~= c;
        }
        else { // escaped char
            if (instring) {
                dst ~= "\",";
                instring = false;
            }
            dst ~= to!string(unEscapeCharLiteral(src[i .. i + 2])) ~ ",";
            i++;
        }
        count++;
        i++;
    }
    if (instring)
        dst ~= '\"';
    else if (count > 0)
        dst = dst[0 .. $ - 1];

    if (count > 0) {
        dst = to!string(count) ~ "," ~ dst;
    }

    return dst;
}

unittest {
    string str;
    str = toAsmStr("");
    assert(str == "", str);
    assert(toAsmStr("a") == `1,"a"`);
    assert(toAsmStr("ab") == `2,"ab"`);
    assert(toAsmStr("abc") == `3,"abc"`);
    str = toAsmStr(r"\n");
    assert(str == "1,10", str);
    assert(toAsmStr(r"\n\r") == "2,10,13");
    str = toAsmStr(r"a\n");
    assert(str == `2,"a",10`, str);
    assert(toAsmStr(r"ab\n") == `3,"ab",10`);
    assert(toAsmStr(r"abc\n") == `4,"abc",10`);
    assert(toAsmStr(r"\na") == `2,10,"a"`);
    assert(toAsmStr(r"\nab") == `3,10,"ab"`);
    assert(toAsmStr(r"\nabc") == `4,10,"abc"`);
    assert(toAsmStr(r"a\na") == `3,"a",10,"a"`);
    assert(toAsmStr(r"ab\nab") == `5,"ab",10,"ab"`);
    assert(toAsmStr(r"abc\nabc") == `7,"abc",10,"abc"`);
}

void emitData() {
    writeln("; Constant strings");
    foreach (v; symboltable.values) {
        string tabs = generate!(() => '\t').takeExactly((24 - v.name.length) / 8 + 1).array;
        if (v.kind == Kind.Constant) {
            if (v.type == Type.Byte && v.isString) {
                writeln(v.name, ":", tabs, "ascii ", toAsmStr(v.value));
            }
        }
    }
    writeln("  org 0x8000");
    writeln("; variables");
    foreach (v; symboltable.values) {
        // todo check if there is an array.
        string tabs = generate!(() => '\t').takeExactly((24 - v.name.length) / 8 + 1).array;
        if (v.kind == Kind.Variable) {
            switch (v.type) {
            case Type.Byte:
                if (v.isString) {
                    writeln(v.name, ":", tabs, "ascii ", toAsmStr(v.value));
                }
                else {
                    string value = v.value;
                    if (value == "")
                        value = "0";
                    if (v.count > 1)
                        writeln(v.name, ":", tabs, "dc    ", v.count, ",",
                                value, "\t\t; ", v.code);
                    else
                        writeln(v.name, ":", tabs, "db    ", value, "\t\t; ", v.code);
                }

                break;
            case Type.Word:
                writeln(v.name, ":", tabs, "word ", v.value, "\t\t; ", v.code);
                break;
            default:
                writeln("Unknown type: ", v);
                break;
            }
        }
    }

}

Type textToType(string typename) {
    switch (typename) {
    case "byte":
    case "ubyte":
        return Type.Byte;
    case "word":
    case "uword":
        return Type.Word;
    case "bool":
        return Type.Bool;
    default:
        return Type.None;
    }
}

bool isTypeSigned(string typename) {
    return typename[0] == 'u';
}

void emitSimpleDecl(ParseTree node) {
    string srctext = strip(node.input[node.begin .. node.end]).replace("\n", " ");
    Type type = textToType(node.matches[2]);
    bool isSigned = isTypeSigned(node.matches[2]);
    string identifier = node.matches[0];
    bool ispointer = false;
    int count = 0;
    string value = "";
    if (node.children.length > 2) {
        if (node.children[2].name == "Retro8.TypeSuffix") {
            ispointer = true;
            if (node.children[2].children.length > 0) {
                // fixed size array
                count = to!int(node.children[2].children[0].matches[0]);
            }
        }
        else if (node.children[2].name == "Retro8.Literal")
            value = node.children[2].children[0].matches[0];
    }

    // add name to symbol tables
    Symbol symbol = new Symbol(Kind.Variable, "v_" ~ identifier, type, "",
            isSigned, ispointer, false, value, srctext, count);
    if (node.children.length > 3)
        symbol.value = node.matches[4];
    symboltable[identifier] = symbol;

    // do type checks here
}

void recordPrototypeParams(ParseTree node, Symbol s) {
    if (node.name == "Retro8.ProtoParameters") {
        if (node.children.length > 0)
            recordPrototypeParams(node.children[0], s);
    }
    else if (node.name == "Retro8.ParamTypeList") {
        bool ispointer = node.children.length >= 3 && node.children[2].name == "Retro8.TypeSuffix";
        Param param = {
            node.children[0].matches[0].toLower(),
                textToType(node.children[1].matches[0]), ispointer
        };
        s.funcargs ~= param;
        if (node.children.length >= 3) {
            if (node.children[2].name == "Retro8.ParamTypeList") {
                recordPrototypeParams(node.children[2], s);
            }
            else if (node.children.length >= 4) {
                recordPrototypeParams(node.children[3], s);
            }
        }
    }
}

void recordPrototype(ParseTree node) {
    string ident = node.children[0].matches[0];
    Symbol s = new Symbol(Kind.Function, ident, Type.None, "", false, false, false, "", "", 0);
    recordPrototypeParams(node.children[1], s);
    symboltable[ident] = s;

}

void recordConstDecl(ParseTree node) {
    string srctext = strip(node.input[node.begin .. node.end]).replace("\n", " ");
    immutable string identifier = node.children[0].matches[0];
    node = node.children[1];
    immutable string literaltype = node.children[0].name;
    switch (literaltype) {
    case "Retro8.DecLit":
        // todo: check size
        Symbol symbol = new Symbol(Kind.Constant, identifier, Type.Byte, "",
                false, false, false, node.children[0].matches[0], srctext, 0);
        symboltable[identifier] = symbol;
        break;
    case "Retro8.HexLit":
        // todo: check size
        Symbol symbol = new Symbol(Kind.Constant, identifier, Type.Byte, "",
                false, false, false, node.children[0].matches[0], srctext, 0);
        symboltable[identifier] = symbol;
        break;
    case "Retro8.StringLit":
        Symbol symbol = new Symbol(Kind.Constant, identifier, Type.Byte, "",
                false, true, true, node.children[0].matches[0], srctext, 0);
        symboltable[identifier] = symbol;
        break;
    default:
        break;
    }
}

void emitAssembly(ParseTree root, int level) {
    foreach (ref node; root.children) {
        switch (node.name) {
        case "Retro8.ConstDecl":
            recordConstDecl(node);
            break;
        case "Retro8.ProtoSignature":
            recordPrototype(node);
            break;
        case "Retro8.SimpleDecl":
            emitSimpleDecl(node);
            break;
        case "Retro8.Function":
            emitFunctionStart(node);
            emitStatementBlock(node.children[1]);
            emitFunctionEnd(node);
            break;
        default:
            emitAssembly(node, level + 1);
            //                writeln("Error unknown node: " ~ node.name);
            break;
        }
    }
}

void emitStatement(ParseTree node) {
    switch (node.name) {
    case "Retro8.AssignmentStmt":
        emitAssignmentStmt(node);
        break;
    case "Retro8.FuncCall":
        emitFunctionCall(node);
        break;
    case "Retro8.IfStmt":
        emitIfStatement(node);
        break;
    case "Retro8.WhileStmt":
        emitWhileStatement(node);
        break;
    case "Retro8.RepeatUntilStmt":
        emitRepeatUntilStatement(node);
        break;
    case "Retro8.LoopStmt":
        emitLoopStatement(node);
        break;
    case "Retro8.BreakStmt":
        emitBreakStatement(node);
        break;
    case "Retro8.ReturnStmt":
        emitReturnStatement(node);
        break;
    case "Retro8.UnaryExpression":
        emitUnaryExprStatement(node);
        break;
    case "Retro8.AsmStmt":
        writeln(node.children[0].matches[0]);
        break;
    default:
        // just descend
        emitStatementList(node);
        break;
    }
}

void emitUnaryExprStatement(ParseTree node) {
    string srctext = strip(node.input[node.begin .. node.end]).replace("\n", " ");
    bool indirect = node.children[0].name == "Retro8.IndirectAccess";

    if (indirect)
        node = node.children[0];

    string identifier = node.children[0].matches[0];
    string operator = node.children[1].matches[0];
    Symbol s = getSymbolForIdentifier(node.children[0]);
    string op = "  inc  ";
    if (operator == "--")
        op = "  dec  ";
    if (s.kind == Kind.Register) {
        writeln(op, s.register, "\t\t; ", srctext);
    }
    else if (s.kind == Kind.Variable) {
        writeln(op, "(", s.name, ")\t\t; ", srctext);
    }
}

void processLocalDecl(ParseTree node) {
    string srctext = strip(node.input[node.begin .. node.end]).replace("\n", " ");
    Type type = textToType(node.children[2].matches[0]);
    bool isSigned = isTypeSigned(node.matches[2]);
    string identifier = node.children[0].matches[0];
    bool ispointer = node.children.length > 3 && node.children[3].name == "Retro8.TypeSuffix";
    int count = 0;
    string value = "";

    string register = node.children[1].matches[0].toLower();
    // add name to symbol tables
    Symbol symbol = new Symbol(Kind.Register, identifier, type, register,
            isSigned, ispointer, false, value, srctext, count);
    //stderr.writeln("Adding local: ", symbol.tupleof);

    localsymbolstack.back.symbols[identifier] = symbol;

}

void emitStatementList(ParseTree node) {
    foreach (child; node.children)
        emitStatement(child);
}

void emitStatementBlock(ParseTree node) {
    // don't create a new scope. It has been created by the function already
    foreach (child; node.children) {
        if (child.name == "Retro8.LocalVarDecl") {
            processLocalDecl(child);
        }
        if (child.name == "Retro8.StatementList") {
            emitStatementList(child);
        }
    }
}

void emitIfStatement(ParseTree node) {
    ParseTree ifblock = node.children[0];

    immutable string endLabel = "endif_" ~ genIdentifier();
    string nextLabel = "else_" ~ genIdentifier();

    foreach (block; node.children) {
        if (block.name == "Retro8.IfBlock" || block.name == "Retro8.ElIfBlock") {
            immutable string srctext = strip(block.input[block.begin .. block.end]).replace("\n",
                    " ");
            writeln(nextLabel, ":\t\t; ", srctext);
            nextLabel = "else_" ~ genIdentifier();
            emitExpression(block.children[0]); // result ends up in register 'a'
            writeln("  cp   1\t\t; ", srctext);
            writeln("  jr   nz,", nextLabel);
            emitStatementList(block.children[1]);
            writeln("  jp   ", endLabel); // TODO: optimize away by checking if there is a next block
        }
        else if (block.name == "Retro8.ElseBlock") {
            immutable string srctext = "else " ~ strip(block.input[block.begin .. block.end])
                .replace("\n", " ");
            writeln(nextLabel, ":\t\t; ", srctext);
            nextLabel = "else_" ~ genIdentifier();
            emitStatementList(block.children[0]);
        }
    }
    writeln(nextLabel, ":");
    writeln(endLabel, ":\t; endif");

}

void emitBreakStatement(ParseTree node) {
    writeln("  break ; TODO BREAK NOT IMPLEMENTED");
}

void emitWhileStatement(ParseTree node) {

    ParseTree child = node.children[0];

    string srctext = strip(child.input[child.begin .. child.end]).replace("\n", " ");

    immutable string labelEnd = "wend_" ~ genIdentifier();
    immutable string labelLoop = "while_" ~ genIdentifier();
    writeln(labelLoop ~ ":\t; while ", srctext);
    writeln("  push bc");
    emitExpression(child); // result ends up in register 'a'
    writeln("  pop  bc");
    writeln("  cp   1");
    writeln("  jr   nz,", labelEnd);
    emitStatementList(node.children[1]);
    writeln("  jp   ", labelLoop, "\t; wend ", srctext);
    writeln(labelEnd, ":");
}

void emitRepeatUntilStatement(ParseTree node) {

    ParseTree child = node.children[1];
    immutable string labelLoop = "repeat_" ~ genIdentifier();
    writeln(labelLoop ~ ":\t\t; repeat");
    emitStatementList(node.children[0]);
    emitExpression(child); // result ends up in register 'a'
    writeln("  cp   1\t\t; ");

    string srctext = strip(child.input[child.begin .. child.end]).replace("\n", " ");

    writeln("  jr   nz,", labelLoop, "\t\t; until ", srctext);
}

void emitLoopStatement(ParseTree node) {

    immutable string labelLoop = "loop_" ~ genIdentifier();
    writeln(labelLoop, ":\t; loop");
    emitStatementList(node.children[0]);
    writeln("  jp   ", labelLoop, "\t; endloop");
}

void emitReturnStatement(ParseTree node) {
    string srctext = strip(node.input[node.begin .. node.end]).replace("\n", " ");

    if (node.children.length > 0)
        emitExpression(node.children[0]);
    writeln("  ret\t\t\t; ", srctext);
}

int getLine(ParseTree node) {
    int n = 1;
    for (int i = 0; i < node.begin; i++) {
        if (node.input[i] == '\n')
            n++;
    }
    return n;
}

void printError(ParseTree node, string msg) {
    stderr.writeln(filename, "(", getLine(node), ") Error: ", msg, ". Near: ",
            node.input[node.begin .. node.end]);
}

void printWarning(ParseTree node, string msg) {
    stderr.writeln(filename, "(", getLine(node), ") Warning: ", msg,
            ". Near: ", node.input[node.begin .. node.end]);
}

Symbol getSymbolForIdentifier(ParseTree node) {
    string identlit = node.matches[0];

    if (identlit in localsymbolstack.back.symbols) {
        return localsymbolstack.back.symbols[identlit];
    }
    else if (identlit in symboltable) {
        return symboltable[identlit];
    }

    // not in any symbol table
    printError(node, "Unknown identifier");
    exit(1);
    return null;
}

Type getTypeForRegister(string register) {
    switch (register.toLower()) {
    case "af":
    case "bc":
    case "de":
    case "hl":
    case "ix":
    case "iy":
        return Type.Word;
    default:
        return Type.Byte;
    }
}

ubyte unEscapeCharLiteral(string s) {
    if (s[0] == '\\') {
        switch (s[1]) {
        case 'r':
            return 13;
        case 'n':
            return 10;
        case 't':
            return 9;
        case 'b':
            return 8;
        case '\\':
            return '\\';
        default:
            printError(ParseTree(), "Unsupported character literal: " ~ s);
            exit(1);
        }
    }
    return s[0];
}

Type emitLiteral(ParseTree node) {
    string literal = node.matches[0];

    switch (node.name) {
    case "Retro8.DecLit":
    case "Retro8.HexLit":
    case "Retro8.BinLit":
    case "Retro8.OctLit":
        // TODO: convert the literal. If larger than 8 bit
        writeln("  ld   a,", literal);
        return Type.Byte;
    case "Retro8.CharLit":
        writeln("  ld   a,", unEscapeCharLiteral(literal));
        return Type.Byte;
    case "Retro8.BoolLit":
        writeln("  ld   a,", (literal == "true" ? "1" : "0"));
        return Type.Bool;
    case "Retro8.StringLit":
        // string literal found. put it constant list
        string identifier = genIdentifier();
        Symbol symbol = new Symbol(Kind.Constant, identifier, Type.Byte, "",
                false, true, true, literal, "", 0);
        symboltable[identifier] = symbol;
        writeln("  ld   bc,", identifier, "\t; ad-hoc string literal");
        return Type.Word;
    default:
        stderr.writeln("Unknown literal type: ", node.name);
        break;
    }
    return Type.Byte;
}

Type emitIdentifier(ParseTree node) {
    // variable or constant (i.e. memory, constant or register)
    Symbol s = getSymbolForIdentifier(node);

    Type type = s.type;

    switch (s.kind) {
    case Kind.Constant:
        if (s.type == Type.Word)
            writeln("  ld   bc,", s.name,
                    "\t\t; const word", __LINE__);
        else
            writeln("  ld   a,", s.name, "\t\t; const byte", __LINE__);
        break;
    case Kind.Variable:
        if (s.type == Type.Word || s.isPointer) {
            if (s.name != "bc") {
                writeln("  ld   bc,", s.name, "\t\t; var word ", __LINE__);
            }
            type = Type.Word;
        }
        else {
            if (s.name != "a")
                writeln("  ld   a,(", s.name, ")\t; var byte ", __LINE__);
        }
        break;
    case Kind.Register:
        if (s.type == Type.Word || s.isPointer) {
            if (s.register != "bc") {
                writeln("  push ", s.register, "\t\t; reg word");
                writeln("  pop  bc");
            }
            type = Type.Word;
        }
        else {
            if (s.register[0] != 'a')
                writeln("  ld   a,", s.register, "\t\t; reg byte");
        }
        break;
    default:
        stderr.writeln("Internal compiler error. Unknown symbol");
        break;
    }

    return type;

}

Type emitPortRead(ParseTree node) {
    // resolve the symbol if it's an identifier
    string srctext = strip(node.input[node.begin .. node.end]).replace("\n", " ");
    string port;
    if (node.children[0].name == "Retro8.Identifier") {
        Symbol s = getSymbolForIdentifier(node.children[0]);
        if (s.kind == Kind.Constant) {
            port = s.name;
            writeln("  in   a,(", port, ")\t\t; ", srctext);
        }
        else if (s.kind == Kind.Variable) {
            writeln("  ld   c,(", s.name, ")");
            writeln("  in   a,c\t\t; ", srctext);
        }
    }
    return Type.Byte;
}

Type emitRegister(ParseTree node) {
    string register = node.matches[0].toLower();
    switch (register) {
    case "af":
    case "bc":
    case "de":
    case "hl":
    case "ix":
    case "iy":
        if (register != "bc")
            writeln("  ld   bc,", register, "\t\t; emitRegister ", __LINE__);
        return Type.Word;
    default:
        if (register != "a")
            writeln("  ld   a,", register, "\t\t; emitRegister ", __LINE__);
        return Type.Byte;
    }
}

Type emitEvalOperation(ParseTree node) {
    ParseTree op1 = node.children[0];
    ParseTree op2 = node.children[2];
    Type type = Type.Byte;
    // check if we have to descend first
    if (op1.name == "Retro8.SimpleExpression" || op1.name == "Retro8.Term"
            || op1.name == "Retro8.Expression") {
        Type type1 = emitExpression(op1);
        //writeln("  ld   c,a\t\t; store result from op1"); // move a to c
        writeln("  push af\t\t; store result from op1");
        Type type2 = emitExpression(op2);
        if (type1 == Type.Word || type2 == Type.Word)
            type = Type.Word;
        writeln("  ld   b,a\t\t; swap operands");
        writeln("  pop  af\t\t; fetch stored result");
    }
    else {
        Type type1 = emitExpression(op2);
        writeln("  ld   b,a\t\t; store result 3");
        Type type2 = emitExpression(op1);
        if (type1 == Type.Word || type2 == Type.Word)
            type = Type.Word;
    }
    // apply operator

    // emit operator
    switch (node.children[1].name) {
    case "Retro8.AddOp":
        switch (node.children[1].matches[0]) {
        case "+":
            writeln("  add  b");
            break;
        case "-":
            writeln("  sub  b");
            break;
        default:
            break;
        }
        break;
    case "Retro8.MulOp":
        switch (node.children[1].matches[0]) {
        case "*":
            writeln("  call mul");
            break;
        case "/":
            writeln("  call div");
            break;
        case "%":
            writeln("  call div");
            break;
        default:
            break;
        }
        break;
    case "Retro8.RelationOp":
        type = Type.Bool;
        // assume false
        string lblEnd = "cpend_" ~ genIdentifier();
        switch (node.children[1].matches[0]) {
        case "=":
            writeln("  cp   b");
            writeln("  ld   a,0\t\t;");
            writeln("  jr   nz,", lblEnd, ";", __LINE__);
            writeln("  ld   a,1\t\t;");
            break;
        case "!=":
            writeln("  cp   b");
            writeln("  ld   a,0\t\t;");
            writeln("  jr   z,", lblEnd, ";", __LINE__);
            writeln("  ld   a,1\t\t;");
            break;
        case "<":
            string lblnoxor = genIdentifier();
            string lbltrue = genIdentifier();
            writeln("  sub  b");
            writeln("  jp   po,", lblnoxor);
            writeln("  xor  0x80");
            writeln(lblnoxor, ":");
            writeln("  ld   a,0\t\t;");
            writeln("  jp   pe,", lblEnd); // greater
            writeln(lbltrue, ":");
            writeln("  ld   a,1\t\t;");
            break;
        case ">":
            string lblnoxor = genIdentifier();
            string lbltrue = genIdentifier();
            writeln("  sub  b");
            writeln("  jp   po,", lblnoxor);
            writeln("  xor  0x80");
            writeln(lblnoxor, ":");
            writeln("  ld   a,0\t\t;");
            writeln("  jp   m,", lblEnd); // less
            writeln(lbltrue, ":");
            writeln("  ld   a,1\t\t;");
            break;
        case "<=":
            string lblnoxor = genIdentifier();
            string lbltrue = genIdentifier();
            writeln("  sub  b");
            writeln("  jr   z,", lbltrue); // equal
            writeln("  jp   po,", lblnoxor);
            writeln("  xor  0x80");
            writeln(lblnoxor, ":");
            writeln("  ld   a,0\t\t;");
            writeln("  jp   pe,", lblEnd); // greater
            writeln(lbltrue, ":");
            writeln("  ld   a,1\t\t;");
            break;
        case ">=":
            string lblnoxor = genIdentifier();
            string lbltrue = genIdentifier();
            writeln("  sub  b");
            writeln("  jr   z,", lbltrue); // equal
            writeln("  jp   po,", lblnoxor);
            writeln("  xor  0x80");
            writeln(lblnoxor, ":");
            writeln("  ld   a,0\t\t;");
            writeln("  jp   m,", lblEnd); // less
            writeln(lbltrue, ":");
            writeln("  ld   a,1\t\t;");
            break;
        default:
            break;
        }
        writeln(lblEnd ~ ":");
        break;
    default:
        break;
    }
    return type;
}

Type emitExpression(ParseTree node) {
    Type type = Type.Byte;
    switch (node.name) {
    case "Retro8.Register":
        return emitRegister(node);
    case "Retro8.Literal":
        return emitLiteral(node.children[0]);
    case "Retro8.Identifier":
        return emitIdentifier(node);
    case "Retro8.Port":
        return emitPortRead(node);
    case "Retro8.IndirectAccess":
        Symbol s = getSymbolForIdentifier(node.children[0]);
        switch (s.kind) {
        case Kind.Constant:
            writeln("  ld   a,(", s.name, ")\t\t; constant ", __LINE__);
            break;
        case Kind.Register:
            writeln("  ld   a,(", s.register, ")\t\t; register ", __LINE__);
            break;
        case Kind.Variable:
            writeln("  ld   hl,(", s.name, ")\t\tvariable ", __LINE__);
            writeln("  ld   a,(hl)");
            break;
        default:
            printError(node, "Internal compiler error at line " ~ to!string(__LINE__));
            exit(1);
        }
        break;
    case "Retro8.Factor":
    case "Retro8.SimpleExpression":
    case "Retro8.Term":
    case "Retro8.Expression":
        if (node.children.length == 1)
            return emitExpression(node.children[0]);
        else if (node.children.length == 3)
            return emitEvalOperation(node);
        break;
    case "Retro8.FuncCall":
        return emitFunctionCall(node);
    default:
        // TODO: consider the type
        if (node.children.length > 1)
            printWarning(node,
                    "Internal compiler error. More than one child at " ~ to!string(__LINE__));
        foreach (ParseTree child; node.children) {
            return emitExpression(child);
        }
        break;
    }
    return type;
}

void saveRegisters(Symbol s) {
    foreach (arg; s.funcargs) {
        string reg;
        if (arg.register == "a")
            reg = "af";
        else if (arg.register == "b" || arg.register == "c")
            reg = "bc";
        else if (arg.register == "d" || arg.register == "e")
            reg = "de";
        else if (arg.register == "h" || arg.register == "l")
            reg = "hl";
        else
            reg = arg.register;
        writeln("  push ", reg);
    }
}

void restoreRegisters(Symbol s) {
    foreach (arg; s.funcargs) {
        string reg;
        if (arg.register == "a")
            reg = "af";
        else if (arg.register == "b" || arg.register == "c")
            reg = "bc";
        else if (arg.register == "d" || arg.register == "e")
            reg = "de";
        else if (arg.register == "h" || arg.register == "l")
            reg = "hl";
        else
            reg = arg.register;
        writeln("  pop  ", reg);
    }
}

Type emitFunctionCall(ParseTree node) {
    //foreach argument in the list
    string srctext = strip(node.input[node.begin .. node.end]).replace("\n", " ");
    Symbol s = getSymbolForIdentifier(node.children[0]);
    // get the symbol for this function call
    if (s.kind != Kind.Function) {
        printError(node, "Symbol " ~ node.children[0].matches[0] ~ " exists but is not a function");
        exit(1);
    }
    // save register state
    // saveRegisters(s);
    if (node.children.length > 1) {
        if (node.children[1].children.length != s.funcargs.length)
            printError(node, "Expected " ~ to!string(
                    s.funcargs.length) ~ " but found " ~ to!string(
                    node.children[1].children.length) ~ " arguments");
        foreach (i, arg; node.children[1].children) {
            Param p = s.funcargs[i];
            if (p.register == "bc" || p.register == "a")
                continue; // do A or BC register last
            Type type = emitExpression(arg);
            // TODO: check signature and put the arguments in the correct registers
            if (type == Type.Word || s.isPointer) {
                writeln("  push bc\t\t; ld ", p.register, ",bc\t\t; load register");
                writeln("  pop  ", p.register);
            }
            else {
                writeln("  ld   ", p.register, ",a\t\t; load register");
            }
        }
        foreach (i, arg; node.children[1].children) {
            Param p = s.funcargs[i];
            if (p.register != "bc" && p.register != "a")
                continue;
            emitExpression(arg);
        }
    }
    string identifier = node.children[0].matches[0];
    string instruction = "  call " ~ identifier;
    string tabs = generate!(() => '\t').takeExactly((23 - instruction.length) / 8 + 1).array;
    writeln(instruction, tabs, "; ", srctext);
    // restore register state
    // restoreRegisters(s);
    return s.type;
}

void processParamList(ParseTree node, Symbol s) {
    string register = node.children[1].matches[0].toLower();
    Type type = textToType(node.children[2].matches[0]);
    bool ispointer = false;
    if (node.children.length > 3)
        ispointer = node.children[3].name == "Retro8.TypeSuffix";
    string identifier = node.children[0].matches[0];
    bool isSigned = isTypeSigned(node.matches[2]);

    Symbol ls = new Symbol(Kind.Register, identifier, type, register, isSigned,
            ispointer, false, "", "", 0);

    localsymbolstack.back.symbols[identifier] = ls;
    Param p = {register, type, ispointer};
    s.funcargs ~= p;
    if (ispointer) {
        if (node.children.length > 4) {
            processParamList(node.children[4], s);
        }
    }
    else {
        if (node.children.length > 3) {
            processParamList(node.children[3], s);
        }
    }
}

void emitFunctionSignature(ParseTree node) {

    string identifier = node.children[0].matches[0];
    // record  in local symbol table
    LocalScope ls = new LocalScope();
    localsymbolstack ~= ls;

    Type type = Type.None;
    bool isSigned = false;
    if (node.children.length > 2) {
        type = textToType(node.children[3].matches[0]);
        isSigned = isTypeSigned(node.children[3].matches[0]);
    }
    // add the function to the global symbol table
    Symbol s = new Symbol(Kind.Function, identifier, type, "", isSigned, false, false, "", "", 0);
    if (node.children[1].children.length > 0) {
        processParamList(node.children[1].children[0], s);
    }
    symboltable[identifier] = s;
    writeln();
    writeln(node.matches[0] ~ ":\t\t\t; " ~ strip(node.input[node.begin .. node.end]));
}

void emitFunctionStart(ParseTree node) {
    emitFunctionSignature(node.children[0]); // save all registers we're going to use
    /*    if (localsymbolstack.length > 0) {
        Symbol[string] localsymbols = localsymbolstack.back.symbols;
        foreach (Symbol s; localsymbols.values) {
            writeln("  push " ~ s.register);
        }
    }
    writeln("  push hl");
    */
}

void emitFunctionEnd(ParseTree node) {

    // restore registers
    /*    writeln("  pop  hl");
    if (localsymbolstack.length > 0) {
        Symbol[string] localsymbols = localsymbolstack.back.symbols;
        foreach_reverse (Symbol s; localsymbols.values) { // TODO: order is wrong
            writeln("  pop  " ~ s.register);
        }
        // remove variables from symbol table
        localsymbolstack.popBack();
    }
    */
    // TODO: check if the prior to last node is a return statement; then don't do this one.
    writeln("  ret");
    localsymbolstack.popBack();
}

void emitAssignmentStmt(ParseTree node) {

    string srctext = strip(node.input[node.begin .. node.end]).replace("\n", " ");

    // first emit the expression.

    Type rhstype = emitExpression(node.children[1]);

    // Result in BC or in A

    // Now figure out destination.
    string dest;
    if (node.children[0].name == "Retro8.IndirectAccess") {
        node = node.children[0];
        // Indirect access (load mem location)
        Symbol s = getSymbolForIdentifier(node.children[0]);
        if (!s.isPointer)
            printWarning(node, "Assignment makes pointer from integer without a cast: ");

        // check is there is an offset
        string offset = null;
        if (node.children.length > 1) {
            offset = node.children[1].children[0].matches[0];
        }
        // is it a register
        if (s.kind == Kind.Register) {
            dest = s.register;
        }
        else {
            dest = s.name;
        }

        // load value in register ix
        if (rhstype == Type.Byte) {
            if (offset != null) {
                writeln("  ld   ix,", dest, "\t\t; ", srctext);
                writeln("  ld   (ix+", offset, "),a");
            }
            else {
                writeln("  ld   (", dest, "),a\t\t; ", srctext);
            }
        }
        else {
            // can't use offsets and must use arithmetic
            if (offset != null) {
                writeln("  ld   ix,", dest, "\t\t; ", srctext);
                writeln("  ld   de,", offset);
                writeln("  add  ix,de");
                writeln("  ld   (ix)", offset, ",bc");
            }
            else {
                writeln("  ld   (", dest, "),bc\t\t; ", srctext);
            }
        }

    }
    else if (node.children[0].name == "Retro8.Port") {
        node = node.children[0].children[0];
        Symbol s = getSymbolForIdentifier(node);
        if (s.kind == Kind.Constant) {
            writeln("  out  (", s.name, "),a\t\t; ", srctext);
        }
        else if (s.kind == Kind.Variable) {
            writeln("  ld   hl,", s.name, "\t\t; ", srctext);
            writeln("  ld   c,(hl)");
            writeln("  out  (c),a");
        }
        else if (s.kind == Kind.Register) {
            if (s.register != "c")
                writeln("  ld   c,", s.register);
            writeln("  out  (c),a\t\t; ", srctext);
        }
    }
    else {
        // Direct variable ( mem location or register)
        Symbol lhssymbol = getSymbolForIdentifier(node.children[0]);
        if (lhssymbol.kind == Kind.Register) {
            dest = lhssymbol.register;
            if (rhstype == Type.Word) {
                writeln("  push bc\t\t; ld ", dest, ",bc\t\t; F-", srctext);
                writeln("  pop  ", dest);
            }
            else {
                if (lhssymbol.type == Type.Word || lhssymbol.isPointer) {
                    writeln("  ld   ", dest[0], ",0\t\t; G1-", srctext);
                    writeln("  ld   ", dest[1], ",a");
                }
                else {
                    writeln("  ld   ", dest, ",a\t\t; G2-", srctext);
                }
            }
        }
        else {
            dest = lhssymbol.name;
            if (rhstype == Type.Word)
                writeln("  ld   (", dest, "),bc\t\t; H-", srctext);
            else
                writeln("  ld   (", dest, "),a\t\t; I-", srctext);
        }
    }
}
