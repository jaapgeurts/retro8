import std.stdio;
import std.file;
import std.string;
import std.conv;
import std.variant;
import std.random : uniform;
import std.range;
import std.algorithm;

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

    VarList      <  "variables" Comment* '{'  Comment* VarDecl* '}'
    VarDecl      <  SimpleDecl Comment* ';'?  Comment*
    #              / arraydecl ';'?

    ExternList   < "extern" Comment* '{' Comment* Prototype* '}'

    SimpleDecl   <  Identifier ':' Type (':=' Literal)?
    Type         <-  "uint8"
                  / "int8"
                  / "uint16"
                  / "int16"
                  / "char"
                  / "bool"
                  / "string"

    Literal      <- DecLit / BinLit / OctLit / HexLit / BoolLit / StringLit
    DecLit       <~ [0-9]+
    BinLit       <~ '0b' [0-1]+
    OctLit       <~ '0o' [0-7]+
    HexLit       <~ '0x' ([0-9A-F][0-9A-F])+
    BoolLit      <- "true" / "false" 
    StringLit    <- :doublequote ~((!(doublequote / eol)  .)*) :doublequote

    Function     <  "function" Comment* Signature Comment* StatementBlock
    Prototype    <  "function" Comment* ProtoSignature

    Signature    <  Identifier Parameters (':' Type )?
    Parameters   < '(' ParamList? ')'
    ParamList    <  Type Identifier (',' ParamList )?

    ProtoSignature    <  Identifier ProtoParameters (':' Type )?
    ProtoParameters   < '(' ParamTypeList? ')'
    ParamTypeList     <  Type Identifier? (',' ProtoParameters )?

    StatementBlock < '{' Comment* StatementList* '}' 
    StatementList  < Statement Comment* ';'? Comment* (StatementList)*

    Statement       <  AssignmentStmt 
                    / ReturnStmt
                    / IfStmt
                    / WhileStmt
                    / FuncCall

    AssignmentStmt   <  Identifier ':=' Expression
    ReturnStmt       < "return" Expression
 
    IfStmt       < "if" Expression StatementBlock ("else" StatementBlock)?
    WhileStmt    < "while" Expression StatementBlock

    Expression    <  SimpleExpression (RelationOp SimpleExpression)?
    SimpleExpression <  ('+' / '-')? Term (AddOp Term)*
    Term          <  Factor (MulOp Factor)*

    Factor        <  Literal
                    / Identifier ('(' ExprList? ')')?
                    / "null"
                    / FuncCall

    ExprList      <  Expression (',' Expression)*

    RelationOp    <  '<=' / '>=' / '=' / '<' / '>' 
    AddOp         <   "or" / '+' / '-'
    MulOp         <  '%' / '*' / '/' / "and"
                
    FuncCall     <  Identifier '(' ArgList* ')'

    ArgList      <  (Literal / Identifier) (',' ArgList )?

    Comment      <- LineComment / BlockComment
    LineComment  <~ "//" ( !eol . )* eol
    BlockComment <~ "/*" (!"*/" .)* "*/"

    WhiteSpace     <- Eol / ' ' / '\t'

    Eol          <- "\r\n" / '\n' / '\r'
    Eof          <- !.

`));
/*
    Term     < Factor (Add / Sub)*
    Add      < "+" Factor
    Sub      < "-" Factor
    Factor   < Primary (Mul / Div)*
    Mul      < "*" Primary
    Div      < "/" Primary
    Primary  < Parens / Neg / Number / Variable
    Parens   < "(" Term ")"
    Neg      < "-" Primary
    Number   < ~([0-9]+)
    Variable <- identifier*/

enum Kind {
    None,
    Constant,
    Variable,
    Function
}

struct Symbol {
    Kind kind = Kind.None;
    string identifier;
    string type; // uint8, int8, uint16, int16, char, string, bool, func, pointers & arrays
    string value;
    string code;
}

Symbol[string] symboltable;

string genIdentifier() {
    char[] rnd = generate!(() => uniform(0, 26) + 'a').takeExactly(10).map!(v => cast(char) v)
        .array;
    return rnd.idup;
}

void main(string[] args) {

    if (args.length != 2) {
        stderr.writefln("USAGE %s <filename>", args[0]);
    }

    string input = readText(args[1]);

    // Parsing at compile-time:
    ParseTree parseTree1 = Retro8(input);

    // pragma(msg, parseTree1.matches);
    writeln(parseTree1);

    emitAssembly(parseTree1, 0);

    emitData();

}

void emitData() {
    foreach (v; symboltable) {
        if (v.kind == Kind.Variable || (v.kind == Kind.Constant && v.type == "string")) {
            switch (v.type) {
            case "uint8":
            case "int8":
                writeln(v.identifier ~ ":\t\t.byte " ~ v.value ~ "\t\t; " ~ v.code);
                break;
            case "string":
                writeln(v.identifier ~ ":\t\t.ascii " ~ to!string(
                        v.value.length) ~ ",\"" ~ v.value ~ "\"\t\t; " ~ v.code);
                break;
            default:
                writeln("Unknown type: ", v);
                break;
            }
        }
    }
}

void emitAssembly(ParseTree root, int level) {
    foreach (ref node; root.children) {
        switch (node.name) {
        case "Retro8.ConstDecl":
            immutable string identifier = node.children[0].matches[0];
            immutable string literaltype = node.children[1].children[0].name;
            string srctext = strip(node.input[node.begin .. node.end]);
            switch (literaltype) {
            case "Retro8.DecLit":
                Symbol symbol = {
                    Kind.Constant, identifier, "int8",
                        node.children[1].children[0].matches[0], srctext
                };
                symboltable[identifier] = symbol;
                break;
            case "Retro8.StringLit":
                Symbol symbol = {
                    Kind.Constant, identifier, "string",
                        node.children[1].children[0].matches[0], srctext
                };
                symboltable[identifier] = symbol;
                break;
            default:
                break;
            }
            break;
        case "Retro8.ProtoSignature":
            string ident = node.matches[0];
            Symbol s = {Kind.Function, ident, "", "", ""};
            symboltable[ident] = s;
            break;
        case "Retro8.SimpleDecl":
            emitSimpleDecl(node);
            break;
        case "Retro8.Function":
            emitFunctionStart(node);
            emitStatementList(node.children[1].children[0]);
            emitFunctionEnd(node);
            break;
        default:
            emitAssembly(node, level + 1);
            //                writeln("Error unknown node: " ~ node.name);
            break;
        }
    }
}

void emitStatementList(ParseTree node) {
    foreach (child; node.children) {
        switch (child.name) {
        case "Retro8.Assignment":
            emitAssignment(child);
            break;
        case "Retro8.FuncCall":
            emitFunctionCall(child);
            break;
        case "Retro8.CompoundStatement":
            emitCompoundStatement(child);
            break;
        default:
            // just descend
            emitStatementList(child);
            break;
        }
    }
}

void emitCompoundStatement(ParseTree node) {
    ParseTree child = node.children[0];
    immutable string next = genIdentifier();
    if (child.name == "Retro8.IfStmt") {
        emitExpression(child.children[0]); // result ends up in a register
        immutable string srctxt = strip(child.input[child.begin .. child.end]);
        writeln("  ld   hl,"~child.matches[1]~" ;\t\t" ~ srctxt);
        writeln("  ld   a,(hl)");
        writeln("  cp   " ~ child.matches[3]);
        writeln("  jr   nz," ~ next); // TODO: depends on operator
    }
    emitStatementList(node.children[1]);
    writeln(next ~ ":");

}

void emitExpression(ParseTree node) {
    switch (node.name) {
    case "Retro8.Literal":
        if (node.children[0].name == "Retro8.StringLit") {
            string identifier = genIdentifier();
            Symbol s = {
                Kind.Constant, identifier, "string", node.children[0].matches[0], ""
            };
            symboltable[identifier] = s;
            writeln("  ld   a," ~ identifier);
        }
        else {
            string value = node.children[0].matches[0];
            writeln("  ld   a," ~ value);
        }
        break;
    case "Retro8.Identifier":
        // supported are variables, constants or literals
        string identifier = node.matches[0];
        // get the symbol and decide what to do based on it.
        if (identifier !in symboltable) {
            stderr.writefln("Unrecognized identifier '%s'\n", identifier);
            return;
        }
        Symbol symbol = symboltable[identifier];
        if (symbol.kind == Kind.Constant) {
            if (symbol.type == "string") {
                writeln("  ld   a," ~ symbol.identifier);
            }
            else {
                writeln("  ld   a," ~ symbol.value);
            }
        }
        else if (symbol.kind == Kind.Variable) {
            if (symbol.type == "int16" || symbol.type == "uint16") {
                writeln("  ld bc,(" ~ symbol.identifier ~ ")");
            }
            else if (symbol.type == "int8" || symbol.type == "uint8"
                    || symbol.type == "char" || symbol.type == "bool") {
                writeln("  ld   a,(" ~ symbol.identifier ~ ")");
            }
            else if (symbol.type == "string") {
                writeln("  ld   hl," ~ symbol.identifier);
            }
        }
        break;

    default:
        return;
    }
}

void emitFunctionCall(ParseTree node) {
    //foreach argument in the list
    foreach (arg; node.children[1].children) {
        emitExpression(arg);
        writeln("  push a");
    }
    writeln("  call " ~ node.matches[0] ~ "\t\t; " ~ strip(node.input[node.begin .. node.end]));
}

void emitSimpleDecl(ParseTree node) {
    string srctext = strip(node.input[node.begin .. node.end]);
    immutable string type = node.matches[2];
    string identifier = node.matches[0];
    // add name to symbol tables

    Symbol symbol = {Kind.Variable, identifier, type, "", srctext};
    if (node.matches.length > 3)
        symbol.value = node.matches[4];
    symboltable[identifier] = symbol;

    // do type checks here
}

void emitFunctionSignature(ParseTree node) {
    writeln(node.matches[0] ~ ":\t\t\t; " ~ strip(node.input[node.begin .. node.end]));
}

void emitFunctionStart(ParseTree node) {
    //    writeln("  push ix\t; enter");
    //    writeln("  ld   ix, sp\t; ");
    emitFunctionSignature(node.children[0]);
}

void emitFunctionEnd(ParseTree node) {
    //    writeln("  ld   sp,ix\t; leave");
    //    writeln("  pop  sp\t;");
    writeln("  ret");
}

void emitAssignment(ParseTree node) {
    writeln("  ld   a, " ~ node.matches[2]);
    writeln("  ld   hl, " ~ node.matches[0]);
    writeln("  ld   (hl), a\t\t; " ~ strip(node.input[node.begin .. node.end]));
}
