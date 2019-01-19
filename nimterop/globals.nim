import sequtils, sets, tables

import regex

when not declared(CIMPORT):
  import "."/treesitter/runtime

const
  gAtoms* = @[
    "field_identifier",
    "identifier",
    "number_literal",
    "preproc_arg",
    "primitive_type",
    "sized_type_specifier",
    "type_identifier"
  ].toSet()

  gExpressions* = @[
    "parenthesized_expression",
    "bitwise_expression",
    "shift_expression",
    "math_expression"
  ].toSet()

  gEnumVals* = @[
    "identifier",
    "number_literal"
  ].concat(toSeq(gExpressions.items))

type
  Kind* = enum
    exactlyOne
    oneOrMore     # +
    zeroOrMore    # *
    zeroOrOne     # ?
    orWithNext    # !

  Ast* = object
    name*: string
    kind*: Kind
    recursive*: bool
    children*: seq[ref Ast]
    when not declared(CIMPORT):
      tonim*: proc (ast: ref Ast, node: TSNode)
    regex*: Regex

  State* = object
    compile*, defines*, headers*, includeDirs*, searchDirs*: seq[string]

    debug*, past*, preprocess*, pnim*, pretty*, recurse*: bool

    consts*, enums*, procs*, types*: HashSet[string]

    code*, constStr*, currentHeader*, debugStr*, enumStr*, mode*, procStr*, typeStr*: string
    sourceFile*: string # eg, C or C++ source or header file

    ast*: Table[string, seq[ref Ast]]
    data*: seq[tuple[name, val: string]]
    when not declared(CIMPORT):
      grammar*: seq[tuple[grammar: string, call: proc(ast: ref Ast, node: TSNode) {.nimcall.}]]

var
  gStateCT* {.compiletime.}: State
  gStateRT*: State

template nBl*(s: typed): untyped =
  (s.len != 0)

type CompileMode* = enum
  c,
  cpp,

# TODO: can cligen accept enum instead of string?
const modeDefault* = $cpp # TODO: USE this everywhere relevant
