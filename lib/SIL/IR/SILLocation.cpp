//===--- SILLocation.cpp - Location information for SIL nodes -------------===//
//
// This source file is part of the Swift.org open source project
//
// Copyright (c) 2014 - 2017 Apple Inc. and the Swift project authors
// Licensed under Apache License v2.0 with Runtime Library Exception
//
// See https://swift.org/LICENSE.txt for license information
// See https://swift.org/CONTRIBUTORS.txt for the list of Swift project authors
//
//===----------------------------------------------------------------------===//

#include "swift/SIL/SILLocation.h"
#include "swift/SIL/SILModule.h"
#include "swift/AST/Decl.h"
#include "swift/AST/Expr.h"
#include "swift/AST/Pattern.h"
#include "swift/AST/Stmt.h"
#include "swift/AST/Module.h"
#include "swift/Basic/SourceManager.h"
#include "llvm/Support/raw_ostream.h"

using namespace swift;

static_assert(sizeof(SILLocation) <= 2 * sizeof(void *),
              "SILLocation must stay small");

SILLocation::FilenameAndLocation *SILLocation::FilenameAndLocation::
alloc(unsigned line, unsigned column, StringRef filename, SILModule &module) {
  return new (module) FilenameAndLocation(line, column, filename);
}

void SILLocation::FilenameAndLocation::dump() const { print(llvm::dbgs()); }

void SILLocation::FilenameAndLocation::print(raw_ostream &OS) const {
  OS << filename << ':' << line << ':' << column;
}

SourceLoc SILLocation::getSourceLoc() const {
  if (isSILFile())
    return storage.sourceLoc;

  // Don't crash if the location is a FilenameAndLocation.
  // TODO: this is a workaround until rdar://problem/25225083 is implemented.
  if (getStorageKind() == FilenameAndLocationKind)
    return SourceLoc();

  return getSourceLoc(getPrimaryASTNode());
}

SourceLoc SILLocation::getSourceLoc(ASTNodeTy N) const {
  if (N.isNull())
    return SourceLoc();

  if (alwaysPointsToEnd() ||
      is<CleanupLocation>() ||
      is<ImplicitReturnLocation>())
    return getEndSourceLoc(N);

  // Use the start location for the ReturnKind.
  if (is<ReturnLocation>())
    return getStartSourceLoc(N);

  if (auto *decl = N.dyn_cast<Decl*>())
    return decl->getLoc();
  if (auto *expr = N.dyn_cast<Expr*>())
    return expr->getLoc();
  if (auto *stmt = N.dyn_cast<Stmt*>())
    return stmt->getStartLoc();
  if (auto *patt = N.dyn_cast<Pattern*>())
    return patt->getStartLoc();
  llvm_unreachable("impossible SILLocation");
}

SourceLoc SILLocation::getSourceLocForDebugging() const {
  if (isNull())
    return SourceLoc();

  if (isSILFile())
    return storage.sourceLoc;

  if (auto *expr = getPrimaryASTNode().dyn_cast<Expr*>()) {
    // Code that has an autoclosure as location should not show up in
    // the line table (rdar://problem/14627460). Note also that the
    // closure function still has a valid DW_AT_decl_line.  Depending
    // on how we decide to resolve rdar://problem/14627460, we may
    // want to use the regular getLoc instead and rather use the
    // column info.
    if (isa<AutoClosureExpr>(expr))
      return SourceLoc();
  }

  if (hasASTNodeForDebugging())
    return getSourceLoc(storage.extendedASTNodeLoc->forDebugging);

  return getSourceLoc(getPrimaryASTNode());
}

SourceLoc SILLocation::getStartSourceLoc() const {
  if (isAutoGenerated())
    return SourceLoc();
  if (isSILFile())
    return storage.sourceLoc;
  return getStartSourceLoc(getPrimaryASTNode());
}

SourceLoc SILLocation::getStartSourceLoc(ASTNodeTy N) {
  if (auto *decl = N.dyn_cast<Decl*>())
    return decl->getStartLoc();
  if (auto *expr = N.dyn_cast<Expr*>())
    return expr->getStartLoc();
  if (auto *stmt = N.dyn_cast<Stmt*>())
    return stmt->getStartLoc();
  if (auto *patt = N.dyn_cast<Pattern*>())
    return patt->getStartLoc();
  llvm_unreachable("impossible SILLocation");
}

SourceLoc SILLocation::getEndSourceLoc() const {
  if (isAutoGenerated())
    return SourceLoc();
  if (isSILFile())
    return storage.sourceLoc;
  return getEndSourceLoc(getPrimaryASTNode());
}

SourceLoc SILLocation::getEndSourceLoc(ASTNodeTy N) {
  if (auto decl = N.dyn_cast<Decl*>())
    return decl->getEndLoc();
  if (auto expr = N.dyn_cast<Expr*>())
    return expr->getEndLoc();
  if (auto stmt = N.dyn_cast<Stmt*>())
    return stmt->getEndLoc();
  if (auto patt = N.dyn_cast<Pattern*>())
    return patt->getEndLoc();
  llvm_unreachable("impossible SILLocation");
}

DeclContext *SILLocation::getAsDeclContext() const {
  if (!isASTNode())
    return nullptr;
  if (auto *D = getAsASTNode<Decl>())
    return D->getInnermostDeclContext();
  if (auto *E = getAsASTNode<Expr>())
    if (auto *DC = dyn_cast<AbstractClosureExpr>(E))
      return DC;
  return nullptr;
}

SILLocation::FilenameAndLocation SILLocation::decode(SourceLoc Loc,
                                              const SourceManager &SM) {
  FilenameAndLocation DL;
  if (Loc.isValid()) {
    DL.filename = SM.getDisplayNameForLoc(Loc);
    std::tie(DL.line, DL.column) = SM.getPresumedLineAndColumnForLoc(Loc);
  }
  return DL;
}

SILLocation::FilenameAndLocation *SILLocation::getCompilerGeneratedLoc() {
  static FilenameAndLocation compilerGenerated({0, 0, "<compiler-generated>"});
  return &compilerGenerated;
}

static void dumpSourceLoc(SourceLoc loc) {
  if (!loc.isValid()) {
    llvm::dbgs() << "<invalid loc>";
    return;
  }
  const char *srcPtr = (const char *)loc.getOpaquePointerValue();
  unsigned len = strnlen(srcPtr, 20);
  if (len < 20) {
    llvm::dbgs() << '"' << StringRef(srcPtr, len) << '"';
  } else {
    llvm::dbgs() << '"' << StringRef(srcPtr, 20) << "[...]\"";
  }
}

void SILLocation::dump() const {
  if (isNull()) {
    llvm::dbgs() << "<no loc>";
    return;
  }
  if (auto D = getAsASTNode<Decl>())
    llvm::dbgs() << Decl::getKindName(D->getKind()) << "Decl @ ";
  if (auto E = getAsASTNode<Expr>())
    llvm::dbgs() << Expr::getKindName(E->getKind()) << "Expr @ ";
  if (auto S = getAsASTNode<Stmt>())
    llvm::dbgs() << Stmt::getKindName(S->getKind()) << "Stmt @ ";
  if (auto P = getAsASTNode<Pattern>())
    llvm::dbgs() << Pattern::getKindName(P->getKind()) << "Pattern @ ";

  if (isFilenameAndLocation()) {
    getFilenameAndLocation()->dump();
  } else {
    dumpSourceLoc(getSourceLoc());
  }

  if (isAutoGenerated())     llvm::dbgs() << ":auto";
  if (alwaysPointsToEnd())   llvm::dbgs() << ":end";
  if (isInPrologue())        llvm::dbgs() << ":prologue";
  if (isSILFile())           llvm::dbgs() << ":sil";
  if (hasASTNodeForDebugging()) {
    llvm::dbgs() << ":debug[";
    dumpSourceLoc(getSourceLocForDebugging());
    llvm::dbgs() << "]\n";
  }
}

void SILLocation::print(raw_ostream &OS, const SourceManager &SM) const {
  if (isNull()) {
    OS << "<no loc>";
  } else if (isFilenameAndLocation()) {
    getFilenameAndLocation()->print(OS);
  } else {
    getSourceLoc().print(OS, SM);
  }
}

RegularLocation::RegularLocation(Stmt *S, Pattern *P, SILModule &Module) :
  SILLocation(new (Module) ExtendedASTNodeLoc(S, P), RegularKind) {}

ReturnLocation::ReturnLocation(ReturnStmt *RS) :
  SILLocation(ASTNodeTy(RS), ReturnKind) {}

ReturnLocation::ReturnLocation(BraceStmt *BS) :
  SILLocation(ASTNodeTy(BS), ReturnKind) {}

ImplicitReturnLocation::ImplicitReturnLocation(AbstractClosureExpr *E)
  : SILLocation(ASTNodeTy(E), ImplicitReturnKind) { }

ImplicitReturnLocation::ImplicitReturnLocation(ReturnStmt *S)
  : SILLocation(ASTNodeTy(S), ImplicitReturnKind) { }

ImplicitReturnLocation::ImplicitReturnLocation(AbstractFunctionDecl *AFD)
  : SILLocation(ASTNodeTy(AFD), ImplicitReturnKind) { }

ImplicitReturnLocation::ImplicitReturnLocation(SILLocation L)
  : SILLocation(L, ImplicitReturnKind) {
  assert(L.isASTNode<Expr>() ||
         L.isASTNode<ValueDecl>() ||
         L.isASTNode<PatternBindingDecl>() ||
         L.isNull());
}
