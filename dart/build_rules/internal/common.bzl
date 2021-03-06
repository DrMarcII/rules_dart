# Copyright 2016 The Bazel Authors. All rights reserved.
#
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
#    http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.

"""Internal implemenation utility functions for Dart rules.

WARNING: NOT A PUBLIC API.

This code is public only by virtue of the fact that Bazel does not yet support
a mechanism for enforcing limitied visibility of Skylark rules. This code makes
no gurantees of API stability and is intended solely for use by the Dart rules.
"""

SDK_SUMMARIES = "//dart/build_rules/ext:sdk_summaries"
SDK_LIB_FILES = "//dart/build_rules/ext:lib_files"

dart_filetypes = [".dart"]
api_summary_extension = "api.ds"

def label_to_dart_package_name(label):
  """Returns the Dart package name for the specified label.

  External packages resolve to their Pub package names.
  All other packages resolve to a unique identifier based on their repo path.

  Examples:
    //foo/bar/baz:     -> foo.bar.baz
    @package//:package -> package

  Args:
    label: the label whose package name is to be returned.

  Returns:
    The Dart package name associated with the label.
  """
  package_name = label.package
  if label.workspace_root.startswith("external/"):
    package_name = label.workspace_root[len("external/"):]
  if "." in package_name:
    fail("Dart package paths may not contain '.': " + label.package)
  return package_name.replace("/", ".")

def _new_dart_context(label,
                      package,
                      lib_root,
                      srcs=None,
                      dart_srcs=None,
                      data=None,
                      deps=None,
                      strong_summary=None,
                      transitive_srcs=None,
                      transitive_dart_srcs=None,
                      transitive_data=None,
                      transitive_deps=None):
  return struct(
      label=label,
      package=package,
      lib_root=lib_root,
      srcs=set(srcs or []),
      dart_srcs=set(dart_srcs or []),
      data=set(data or []),
      deps=deps or [],
      strong_summary=None,
      transitive_srcs=set(transitive_srcs or []),
      transitive_dart_srcs=set(transitive_dart_srcs or []),
      transitive_data=set(transitive_data or []),
      transitive_deps=dict(transitive_deps or {}),
  )

def make_dart_context(
    ctx,
    package = None,
    lib_root = None,
    srcs = None,
    data = None,
    deps = None,
    pub_pkg_name = None,
    strong_summary = None):
  label = ctx.label
  if not package:
    if not pub_pkg_name:
      package = label_to_dart_package_name(label)
    else:
      package = pub_pkg_name

  if not lib_root:
    lib_root = ""
    if label.workspace_root.startswith("external/"):
      lib_root += label.workspace_root[len("external/"):] + "/"

    if label.package.startswith("vendor/"):
      lib_root += label.package[len("vendor/"):] + "/"
    elif label.package:
      lib_root += label.package + "/"

    lib_root += "lib/"

  srcs = set(srcs or [])
  dart_srcs = filter_files(dart_filetypes, srcs)
  data = set(data or [])
  deps = deps or []
  transitive_srcs, transitive_dart_srcs, transitive_data, transitive_deps = (
      collect_files(srcs, dart_srcs, data, deps))
  return struct(
      label=label,
      package=package,
      lib_root=lib_root,
      srcs=srcs,
      dart_srcs=dart_srcs,
      data=data,
      deps=deps,
      strong_summary=strong_summary,
      transitive_srcs=transitive_srcs,
      transitive_dart_srcs=transitive_dart_srcs,
      transitive_data=transitive_data,
      transitive_deps=transitive_deps,
  )

def collect_files(srcs, dart_srcs, data, deps):
  transitive_srcs = set()
  transitive_dart_srcs = set()
  transitive_data = set()
  transitive_deps = {}
  for dep in deps:
    transitive_srcs += dep.dart.transitive_srcs
    transitive_dart_srcs += dep.dart.transitive_dart_srcs
    transitive_data += dep.dart.transitive_data
    transitive_deps += dep.dart.transitive_deps
    transitive_deps["%s" % dep.dart.label] = dep
  transitive_srcs += srcs
  transitive_dart_srcs += dart_srcs
  transitive_data += data
  return (transitive_srcs, transitive_dart_srcs, transitive_data, transitive_deps)

def _merge_dart_context(dart_ctx1, dart_ctx2):
  """Merges two dart contexts whose package and lib_root must be identical."""
  if dart_ctx1.package != dart_ctx2.package:
    fail("Incompatible packages: %s and %s" % (dart_ctx1.package,
                                               dart_ctx2.package))
  if dart_ctx1.lib_root != dart_ctx2.lib_root:
    fail("Incompatible lib_roots for package %s:\n" % dart_ctx1.package +
         "  %s declares: %s\n" % (dart_ctx1.label, dart_ctx1.lib_root) +
         "  %s declares: %s\n" % (dart_ctx2.label, dart_ctx2.lib_root) +
         "Targets in the same package must declare the same lib_root")

  return _new_dart_context(
      label=dart_ctx1.label,
      package=dart_ctx1.package,
      lib_root=dart_ctx1.lib_root,
      srcs=dart_ctx1.srcs + dart_ctx2.srcs,
      dart_srcs=dart_ctx1.dart_srcs + dart_ctx2.dart_srcs,
      data=dart_ctx1.data + dart_ctx2.data,
      deps=dart_ctx1.deps + dart_ctx2.deps,
      strong_summary=dart_ctx1.strong_summary,
      transitive_srcs=dart_ctx1.transitive_srcs + dart_ctx2.transitive_srcs,
      transitive_dart_srcs=dart_ctx1.transitive_dart_srcs + dart_ctx2.transitive_dart_srcs,
      transitive_data=dart_ctx1.transitive_data + dart_ctx2.transitive_data,
      transitive_deps=dart_ctx1.transitive_deps + dart_ctx2.transitive_deps,
  )

def collect_dart_context(dart_ctx, transitive=True, include_self=True):
  """Collects and returns dart contexts."""
  # Collect direct or transitive deps.
  dart_ctxs = [dart_ctx]
  if transitive:
    dart_ctxs += [d.dart for d in dart_ctx.transitive_deps.values()]
  else:
    dart_ctxs += [d.dart for d in dart_ctx.deps]

  # Optionally, exclude all self-packages.
  if not include_self:
    dart_ctxs = [c for c in dart_ctxs if c.package != dart_ctx.package]

  # Merge Dart context by package.
  ctx_map = {}
  for dc in dart_ctxs:
    if dc.package in ctx_map:
      dc = _merge_dart_context(ctx_map[dc.package], dc)
    ctx_map[dc.package] = dc
  return ctx_map

def package_spec_action(ctx, dart_ctx, output):
  """Creates an action that generates a Dart package spec.

  Arguments:
    ctx: The rule context.
    dart_ctx: The Dart context.
    output: The output package_spec file.
  """
  # There's a 1-to-many relationship between packages and targets, but
  # collect_transitive_packages() asserts that their lib_roots are the same.
  dart_ctxs = collect_dart_context(
      dart_ctx, transitive=True, include_self=True).values()

  # Generate the content.
  content = "# Generated by Bazel\n"
  for dc in dart_ctxs:
    lib_root = dc.lib_root
    if lib_root.startswith("vendor/"):
      lib_root = lib_root[len("vendor/"):]
    relative_lib_root = _relative_path(dart_ctx.label.package, lib_root)
    if dc.package:
      content += "%s:%s\n" % (dc.package, relative_lib_root)

  # Emit the package spec.
  ctx.file_action(
      output=output,
      content=content,
  )

def _relative_path(from_dir, to_path):
  """Returns the relative path from a directory to a path via the repo root."""
  if not from_dir:
    return to_path
  return "../" * (from_dir.count("/") + 1) + to_path

def layout_action(ctx, srcs, output_dir):
  """Generates a flattened directory of sources.

  For each file f in srcs, a file is emitted at output_dir/f.short_path.
  Returns a dict mapping short_path to the emitted file.

  Args:
    ctx: the build context.
    srcs: the set of input srcs to be flattened.
    output_dir: the full output directory path into which the files are emitted.

  Returns:
    A map from input file short_path to File in output_dir.
  """
  commands = []
  output_files = {}
  # TODO(cbracken) extract next two lines to func
  if not output_dir.endswith("/"):
    output_dir += "/"
  for src_file in srcs:
    short_better_path = src_file.short_path
    if short_better_path.startswith('../'):
      dest_file = ctx.new_file(output_dir + short_better_path.replace("../", ""))
    else:
      dest_file = ctx.new_file(output_dir + short_better_path)
    dest_dir = dest_file.path[:dest_file.path.rfind("/")]
    link_target = _relative_path(dest_dir, src_file.path)
    commands += ["ln -s '%s' '%s'" % (link_target, dest_file.path)]
    output_files[src_file.short_path] = dest_file

  # Emit layout script.
  layout_cmd = ctx.new_file(ctx.label.name + "_layout.sh")
  ctx.file_action(
      output=layout_cmd,
      content="#!/bin/bash\n" + "\n".join(commands),
      executable=True,
  )

  # Invoke the layout action.
  ctx.action(
      inputs=list(srcs),
      outputs=output_files.values(),
      executable=layout_cmd,
      progress_message="Building flattened source layout for %s" % ctx,
      mnemonic="DartLayout",
  )
  return output_files

# Check if `srcs` contains at least some dart files
def has_dart_sources(srcs):
  for n in srcs:
    if n.path.endswith(".dart"):
      return True
  return False

def filter_files(filetypes, files):
  """Filters a list of files based on a list of strings."""
  filtered_files = []
  for file_to_filter in files:
    for filetype in filetypes:
      if str(file_to_filter).endswith(filetype):
        filtered_files.append(file_to_filter)
        break

  return filtered_files

def make_package_uri(dart_ctx, short_path, prefix=""):
  if short_path.startswith("../"):
    short_path = short_path.replace("../","")
  if short_path.startswith(dart_ctx.lib_root):
    return "package:%s/%s" % (
        dart_ctx.package, short_path[len(dart_ctx.lib_root):])
  else:
    return "file:///%s%s" % (prefix, short_path)

def compute_layout(srcs):
  """Computes a dict mapping short_path to file.

  This is similar to the dict returned by layout_action, except that
  the files in the dict are the original files rather than symbolic
  links.
  """
  output_files = {}
  for src_file in srcs:
    output_files[src_file.short_path] = src_file
  return output_files

def relative_path(from_dir, to_path):
  """Returns the relative path from a directory to a path via the repo root."""
  return "../" * (from_dir.count("/") + 1) + to_path

def strip_extension(path):
  index = path.rfind(".")
  if index == -1:
    return path
  return path[0:index]
