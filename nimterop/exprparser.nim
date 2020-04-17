import strformat, strutils, macros

import regex

import compiler/[ast, renderer]

import "."/treesitter/[api, c, cpp]

import "."/[globals, getters, utils]

type
  ExprParser* = ref object
    state*: NimState
    code*: string

  ExprParseError* = object of CatchableError

proc newExprParser*(state: NimState, code: string): ExprParser =
  ExprParser(state: state, code: code)

template techo(msg: varargs[string, `$`]) =
  if exprParser.state.gState.debug:
    let nimState {.inject.} = exprParser.state
    necho join(msg, "").getCommented

template val(node: TSNode): string =
  exprParser.code.getNodeVal(node)

proc mode(exprParser: ExprParser): string =
  exprParser.state.gState.mode

template withCodeAst(exprParser: ExprParser, body: untyped): untyped =
  ## A simple template to inject the TSNode into a body of code
  var parser = tsParserNew()
  defer:
    parser.tsParserDelete()

  doAssert exprParser.code.nBl, "Empty code"
  if exprParser.mode == "c":
    doAssert parser.tsParserSetLanguage(treeSitterC()), "Failed to load C parser"
  elif exprParser.mode == "cpp":
    doAssert parser.tsParserSetLanguage(treeSitterCpp()), "Failed to load C++ parser"
  else:
    doAssert false, &"Invalid parser {exprParser.mode}"

  var
    tree = parser.tsParserParseString(nil, exprParser.code.cstring, exprParser.code.len.uint32)
    root {.inject.} = tree.tsTreeRootNode()

  body

  defer:
    tree.tsTreeDelete()

proc getNumNode(number, suffix: string): PNode {.inline.} =
  ## Convert a C number to a Nim number PNode
  result = newNode(nkNone)
  if number.contains("."):
    let floatSuffix = number[result.len-1]
    try:
      case floatSuffix
      of 'l', 'L':
        # TODO: handle long double (128 bits)
        # result = newNode(nkFloat128Lit)
        result = newFloatNode(nkFloat64Lit, parseFloat(number[0 ..< number.len - 1]))
      of 'f', 'F':
        result = newFloatNode(nkFloat64Lit, parseFloat(number[0 ..< number.len - 1]))
      else:
        result = newFloatNode(nkFloatLit, parseFloat(number[0 ..< number.len - 1]))
      return
    except ValueError:
      raise newException(ExprParseError, &"Could not parse float value \"{number}\".")

  case suffix
  of "u", "U":
    result = newNode(nkUintLit)
  of "l", "L":
    result = newNode(nkInt32Lit)
  of "ul", "UL":
    result = newNode(nkUint32Lit)
  of "ll", "LL":
    result = newNode(nkInt64Lit)
  of "ull", "ULL":
    result = newNode(nkUint64Lit)
  else:
    result = newNode(nkIntLit)

  # I realize these regex are wasteful on performance, but
  # couldn't come up with a better idea.
  if number.contains(re"0[xX]"):
    result.intVal = parseHexInt(number)
    result.flags = {nfBase16}
  elif number.contains(re"0[bB]"):
    result.intVal = parseBinInt(number)
    result.flags = {nfBase2}
  elif number.contains(re"0[oO]"):
    result.intVal = parseOctInt(number)
    result.flags = {nfBase8}
  else:
    result.intVal = parseInt(number)

proc processNumberLiteral*(exprParser: ExprParser, node: TSNode): PNode =
  result = newNode(nkNone)
  let nodeVal = node.val

  var match: RegexMatch
  const reg = re"(\-)?(0\d+|0[xX][0-9a-fA-F]+|0[bB][01]+|\d+|\d+\.?\d*[fFlL]?|\d*\.?\d+[fFlL]?)([ulUL]*)"
  let found = nodeVal.find(reg, match)
  if found:
    let
      prefix = if match.group(0).len > 0: nodeVal[match.group(0)[0]] else: ""
      number = nodeVal[match.group(1)[0]]
      suffix = nodeVal[match.group(2)[0]]

    result = getNumNode(number, suffix)

    if result.kind != nkNone and prefix == "-":
      result = nkPrefix.newTree(
        exprParser.state.getIdent("-"),
        result
      )
  else:
    raise newException(ExprParseError, &"Could not find a number in number_literal: \"{nodeVal}\"")

proc processCharacterLiteral*(exprParser: ExprParser, node: TSNode): PNode =
  result = newNode(nkCharLit)
  result.intVal = node.val[1].int64

proc processStringLiteral*(exprParser: ExprParser, node: TSNode): PNode =
  let nodeVal = node.val
  result = newStrNode(nkStrLit, nodeVal[1 ..< nodeVal.len - 1])

proc processTSNode*(exprParser: ExprParser, node: TSNode, typeofNode: PNode = nil): PNode

proc processShiftExpression*(exprParser: ExprParser, node: TSNode, typeofNode: PNode = nil): PNode =
  result = newNode(nkInfix)
  let
    left = node[0]
    right = node[1]
  var shiftSym = exprParser.code[left.tsNodeEndByte() ..< right.tsNodeStartByte()].strip()

  case shiftSym
  of "<<":
    result.add exprParser.state.getIdent("shl")
  of ">>":
    result.add exprParser.state.getIdent("shr")
  else:
    raise newException(ExprParseError, &"Unsupported shift symbol \"{shiftSym}\"")

  let leftNode = exprParser.processTSNode(left, typeofNode)

  var tnode = typeofNode
  if tnode.isNil:
    tnode = leftNode

  let rightNode = exprParser.processTSNode(right, tnode)

  result.add leftNode
  result.add nkCast.newTree(
    nkCall.newTree(
      exprParser.state.getIdent("typeof"),
      tnode
    ),
    rightNode
  )

proc processParenthesizedExpr*(exprParser: ExprParser, node: TSNode, typeofNode: PNode = nil): PNode =
  result = newNode(nkPar)
  for i in 0 ..< node.len():
    result.add(exprParser.processTSNode(node[i], typeofNode))

proc processLogicalExpression*(exprParser: ExprParser, node: TSNode, typeofNode: PNode = nil): PNode =
  result = newNode(nkPar)
  let child = node[0]
  var nimSym = ""

  var binarySym = exprParser.code[node.tsNodeStartByte() ..< child.tsNodeStartByte()].strip()
  techo "LOG SYM: ", binarySym

  case binarySym
  of "!":
    nimSym = "not"
  else:
    raise newException(ExprParseError, &"Unsupported logical symbol \"{binarySym}\"")

  techo "LOG CHILD: ", child.val, ", nim: ", nimSym
  result.add nkPrefix.newTree(
    exprParser.state.getIdent(nimSym),
    exprParser.processTSNode(child, typeofNode)
  )

proc processMathExpression(exprParser: ExprParser, node: TSNode, typeofNode: PNode = nil): PNode =
  if node.len > 1:
    # Node has left and right children ie: (2 + 7)
    var
      res = newNode(nkInfix)
    let
      left = node[0]
      right = node[1]

    let mathSym = exprParser.code[left.tsNodeEndByte() ..< right.tsNodeStartByte()].strip()
    techo "MATH SYM: ", mathSym

    res.add exprParser.state.getIdent(mathSym)
    let leftNode = exprParser.processTSNode(left, typeofNode)

    var tnode = typeofNode
    if tnode.isNil:
      tnode = leftNode

    let rightNode = exprParser.processTSNode(right, tnode)

    res.add leftNode
    # res.add rightNode
    res.add nkCast.newTree(
      nkCall.newTree(
        exprParser.state.getIdent("typeof"),
        tnode
      ),
      rightNode
    )

    # Make sure the statement is of the same type as the left
    # hand argument, since some expressions return a differing
    # type than the input types (2/3 == float)
    result = nkCall.newTree(
      nkCall.newTree(
        exprParser.state.getIdent("typeof"),
        tnode
      ),
      res
    )

  elif node.len() == 1:
    # Node has only one child, ie -(20 + 7)
    result = newNode(nkPar)
    let child = node[0]
    var nimSym = ""

    let unarySym = exprParser.code[node.tsNodeStartByte() ..< child.tsNodeStartByte()].strip()
    techo "MATH SYM: ", unarySym

    case unarySym
    of "+":
      nimSym = "+"
    of "-":
      # Special case. The minus symbol must be in front of an integer,
      # so we have to make a gental cast here to coerce it to one.
      # Might be bad because we are overwriting the type
      # There's probably a better way of doing this
      result.add nkPrefix.newTree(
        exprParser.state.getIdent(unarySym),
        nkPar.newTree(
          nkCall.newTree(
            exprParser.state.getIdent("int64"),
            exprParser.processTSNode(child, typeofNode)
          )
        )
      )
      return
    else:
      raise newException(ExprParseError, &"Unsupported unary symbol \"{unarySym}\"")

    result.add nkPrefix.newTree(
      exprParser.state.getIdent(nimSym),
      exprParser.processTSNode(child, typeofNode)
    )
  else:
    raise newException(ExprParseError, &"Invalid bitwise_expression \"{node.val}\"")

proc processBitwiseExpression(exprParser: ExprParser, node: TSNode, typeofNode: PNode = nil): PNode =
  if node.len() > 1:
    result = newNode(nkInfix)

    let
      left = node[0]
      right = node[1]

    var nimSym = ""

    var binarySym = exprParser.code[left.tsNodeEndByte() ..< right.tsNodeStartByte()].strip()
    techo "BIN SYM: ", binarySym

    case binarySym
    of "|", "||":
      nimSym = "or"
    of "&", "&&":
      nimSym = "and"
    of "^":
      nimSym = "xor"
    else:
      raise newException(ExprParseError, &"Unsupported binary symbol \"{binarySym}\"")

    result.add exprParser.state.getIdent(nimSym)
    let leftNode = exprParser.processTSNode(left, typeofNode)

    var tnode = typeofNode
    if tnode.isNil:
      tnode = leftNode

    let rightNode = exprParser.processTSNode(right, tnode)

    result.add leftNode
    result.add nkCall.newTree(
      nkCall.newTree(
        exprParser.state.getIdent("typeof"),
        tnode
      ),
      rightNode
    )

  elif node.len() == 1:
    result = newNode(nkPar)
    let child = node[0]
    var nimSym = ""

    var unarySym = exprParser.code[node.tsNodeStartByte() ..< child.tsNodeStartByte()].strip()
    techo "BIN SYM: ", unarySym

    case unarySym
    of "~":
      nimSym = "not"
    else:
      raise newException(ExprParseError, &"Unsupported unary symbol \"{unarySym}\"")

    result.add nkPrefix.newTree(
      exprParser.state.getIdent(nimSym),
      exprParser.processTSNode(child, typeofNode)
    )
  else:
    raise newException(ExprParseError, &"Invalid bitwise_expression \"{node.val}\"")

proc processTSNode(exprParser: ExprParser, node: TSNode, typeofNode: PNode = nil): PNode =
  ## Handle all of the types of expressions here. This proc gets called recursively
  ## in the processX procs and will drill down to sub nodes.
  result = newNode(nkNone)
  let nodeName = node.getName()
  techo "NODE: ", nodeName, ", VAL: ", node.val
  case nodeName
  of "number_literal":
    result = exprParser.processNumberLiteral(node)
  of "string_literal":
    result = exprParser.processStringLiteral(node)
  of "char_literal":
    result = exprParser.processCharacterLiteral(node)
  of "expression_statement", "ERROR", "translation_unit":
    # This may be wrong. What can be in an expression?
    if node.len > 0:
      result = exprParser.processTSNode(node[0], typeofNode)
    else:
      raise newException(ExprParseError, &"Node type \"{nodeName}\" has no children")
  of "parenthesized_expression":
    result = exprParser.processParenthesizedExpr(node, typeofNode)
  of "bitwise_expression":
    result = exprParser.processBitwiseExpression(node, typeofNode)
  of "math_expression":
    result = exprParser.processMathExpression(node, typeofNode)
  of "shift_expression":
    result = exprParser.processShiftExpression(node, typeofNode)
  of "logical_expression":
    result = exprParser.processLogicalExpression(node, typeofNode)
  # Why are these node types named true/false?
  of "true", "false":
    result = exprParser.state.parseString(node.val)
  of "identifier":
    var ident = node.val
    if ident != "_":
      # Process the identifier through cPlugin
      ident = exprParser.state.getIdentifier(ident, nskConst)
      techo ident
    if ident != "":
      result = exprParser.state.getIdent(ident)
    if result.kind == nkNone:
      raise newException(ExprParseError, &"Could not get identifier \"{ident}\"")
  else:
    raise newException(ExprParseError, &"Unsupported node type \"{nodeName}\" for node \"{node.val}\"")

  techo "NODE RES: ", result

proc codeToNode*(state: NimState, code: string): PNode =
  ## Convert the C string to a nim PNode tree
  result = newNode(nkNone)
  try:
    let exprParser = newExprParser(state, code)
    withCodeAst(exprParser):
      result = exprParser.processTSNode(root)
  except ExprParseError as e:
    echo e.msg.getCommented
    result = newNode(nkNone)
  except Exception as e:
    echo e.msg.getCommented
    result = newNode(nkNone)