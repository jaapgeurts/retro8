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
 
    IfStmt           < "if" Expression StatementBlock ("else" StatementBlock)?
    WhileStmt        < "while" Expression StatementBlock

    Expression    <  SimpleExpression (RelationOp SimpleExpression)?
    SimpleExpression <  ( '+' / '-' )? Term (AddOp Term)*
    Term          <  Factor (MulOp Factor)*

    Factor        <  Literal
                    / Identifier
                    / '(' Expression ')'
                    / "null"
                    / FuncCall

    ExprList      <  Expression (',' Expression)*

    RelationOp    <  '<=' / '>=' / '!=' / '=' / '<' / '>' 
    AddOp         <   "or" / '+' / '-'
    MulOp         <  '%' / '*' / '/' / "and"
                
    FuncCall     <  Identifier '(' ArgList* ')'

    ArgList      <  (Literal / Identifier) (',' (Literal / Identifier) )*

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

    parseTree1 = simplifyTree(parseTree1);

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
            immutable string literaltype = node.children[1].name;
            string srctext = strip(node.input[node.begin .. node.end]);
            switch (literaltype) {
            case "Retro8.DecLit":
                Symbol symbol = {
                    Kind.Constant, identifier, "int8", node.children[1].matches[0], srctext
                };
                symboltable[identifier] = symbol;
                break;
            case "Retro8.StringLit":
                Symbol symbol = {
                    Kind.Constant, identifier, "string", node.children[1].matches[0], srctext
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
            emitStatementList(node.children[1]);
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
        case "Retro8.AssignmentStmt":
            emitAssignmentStmt(child);
            break;
        case "Retro8.FuncCall":
            emitFunctionCall(child);
            break;
        case "Retro8.IfStmt":
            emitIfStatement(child);
            break;
        default:
            // just descend
            emitStatementList(child);
            break;
        }
    }
}

void emitIfStatement(ParseTree node) {
    ParseTree child = node.children[0];
    immutable string label = genIdentifier();
    immutable string srctxt = "if " ~ strip(child.input[child.begin .. child.end]);
    emitExpression(child); // result ends up in register 'a'
    writeln("  cp   1\t\t; " ~ srctxt);
    writeln("  jr   nz," ~ label); // TODO: depends on operator
    emitStatementList(node.children[1]);
    writeln(label ~ ":");

}

void emitOperand(string register, ParseTree node) {
    string identlit = node.matches[0];
    switch (node.name) {
    case "Retro8.Identifier":
        // variable or constant
        if (identlit !in symboltable) {
            stderr.writeln("Unknown identifier near: " ~ node.input[node.begin .. node.end]);
        }
        else {
            Symbol s = symboltable[identlit];
            if (s.kind == Kind.Constant) {
                if (s.type == "string")
                    writeln("  ld   " ~ register ~ "," ~ s.identifier);
                else
                    writeln("  ld   " ~ register ~ "," ~ s.value);
            }
            else if (s.kind == Kind.Variable) {
                if (s.type == "string")
                    writeln("  ld   a," ~ identlit);
                else
                    writeln("  ld   a,(" ~ identlit ~ ")");
            }
        }
        break;
    case "Retro8.DecLit":
        writeln("  ld   " ~ register ~ "," ~ identlit);
        break;
    case "Retro8.HexLit":
        writeln("  ld   " ~ register ~ "," ~ identlit);
        break;
    case "Retro8.BoolLit":
        writeln("  ld   " ~ register ~ "," ~ identlit == "true" ? "1" : "0");
        break;
    case "Retro8.BinLit":
        writeln("  ld   " ~ register ~ "," ~ identlit);
        break;
    case "Retro8.OctLit":
        writeln("  ld   " ~ register ~ "," ~ identlit);
        break;
    default:
        stderr.writeln(
                "String literals not supported in expression: " ~ node.input[node.begin .. node.end]);
        break;
    }
}

void emitExpression(ParseTree node) {
    string register;

    // go to the bottom first. on the way back emit calculation
    foreach (child; node.children) {
        emitExpression(child);
    }
    if (node.name == "Retro8.SimpleExpression" || node.name == "Retro8.Term"
            || node.name == "Retro8.Expression") {
        ParseTree op1 = node.children[0];
        ParseTree op2 = node.children[2];

        if (op2.name == "Retro8.SimpleExpression" || op2.name == "Retro8.Term") {
            writeln("  ld   d,a\t\t; store expression result");
        }
        emitOperand("a", op1);
        if (op2.name == "Retro8.SimpleExpression" || op2.name == "Retro8.Term") {
            register = "d";
        }
        else {
            register = "b";
            emitOperand("b", op2);
        }
        // emit operator
        switch (node.children[1].name) {
        case "Retro8.AddOp":
            switch (node.children[1].matches[0]) {
            case "+":
                writeln("  add  " ~ register);
                break;
            case "-":
                writeln("  sub  " ~ register);
                break;
            default:
                break;
            }
            break;
        case "Retro8.MulOp":
            if (register == "d")
                writeln("  ld   b,d");
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
            writeln("  cp   " ~ register);
            string lblFalse = genIdentifier();
            switch (node.children[1].matches[0]) {
            case "=":
                writeln("  jr   nz," ~ lblFalse);
                break;
            case "!=":
                writeln("  jr   z," ~ lblFalse);
                break;
            case "<":
                writeln("  jr   nc," ~ lblFalse);
                break;
            case ">":
                writeln("  jr   c," ~ lblFalse);
                break;
            case "<=":
                writeln("  jr   c," ~ lblFalse);
                writeln("  jr   nz," ~ lblFalse);
                break;
            case ">=":
                writeln("  jr   nc," ~ lblFalse);
                writeln("  jr   nz," ~ lblFalse);
                break;
            default:
                break;
            }
            string lblEndIf = genIdentifier();
            writeln("  ld   a,1\t\t; true");
            writeln("  jr   " ~ lblEndIf);
            writeln(lblFalse ~ ":");
            writeln("  ld   a,0\t\t; false");
            writeln(lblEndIf ~ ":");
            break;
        default:
            break;
        }
    }
    return;

}

void emitIdentLiteral(ParseTree node) {
    string identlit = node.matches[0];
    switch (node.name) {
    case "Retro8.Identifier":
        // variable or constant
        if (identlit !in symboltable) {
            stderr.writeln("Unknown identifier near: " ~ node.input[node.begin .. node.end]);
        }
        else {
            Symbol s = symboltable[identlit];
            if (s.kind == Kind.Constant) {
                if (s.type == "string")
                    writeln("  ld   a," ~ s.identifier);
                else
                    writeln("  ld   a," ~ s.value);
            }
            else if (s.kind == Kind.Variable) {
                if (s.type == "string")
                    writeln("  ld   a," ~ identlit);
                else
                    writeln("  ld   a,(" ~ identlit ~ ")");
            }
        }
        break;
    case "Retro8.DecLit":
        writeln("  ld   a," ~ identlit);
        break;
    case "Retro8.HexLit":
        writeln("  ld   a," ~ identlit);
        break;
    case "Retro8.BoolLit":
        writeln("  ld   a," ~ identlit);
        break;
    case "Retro8.BinLit":
        writeln("  ld   a," ~ identlit);
        break;
    case "Retro8.OctLit":
        writeln("  ld   a," ~ identlit);
        break;
    case "Retro8.StringLit":
        // string literal found. put it constant list
        string identifier = genIdentifier();
        Symbol symbol = {Kind.Constant, identifier, "string", identlit, ""};
        symboltable[identifier] = symbol;
        writeln("  ld   hl," ~ identifier);
        break;
    default:
        break;
    }
}

void emitFunctionCall(ParseTree node) {
    //foreach argument in the list
    if (node.children[1].name == "Retro8.ArgList") {
        foreach (arg; node.children[1].children) {
            emitIdentLiteral(arg);
        }
    }
    else {
        emitIdentLiteral(node.children[1]);
    }
    writeln("  call " ~ node.children[0].matches[0] ~ "\t\t; " ~ strip(
            node.input[node.begin .. node.end]));
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

void emitAssignmentStmt(ParseTree node) {
    writeln("            \t\t; " ~ strip(node.input[node.begin .. node.end]));
    emitExpression(node.children[1]);
    writeln("  ld   hl, " ~ node.children[0].matches[0]);
    writeln("  ld   (hl), a");
}
