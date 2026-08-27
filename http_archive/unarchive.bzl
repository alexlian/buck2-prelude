# Copyright (c) Meta Platforms, Inc. and affiliates.
#
# This source code is dual-licensed under either the MIT license found in the
# LICENSE-MIT file in the root directory of this source tree or the Apache
# License, Version 2.0 found in the LICENSE-APACHE file in the root directory
# of this source tree. You may select, at your option, one of the
# above-listed licenses.

load("@prelude//os_lookup:defs.bzl", "Os", "OsLookup")
load("@prelude//utils:expect.bzl", "expect")
load("@prelude//utils:utils.bzl", "value_or")
load(":exec_deps.bzl", "HttpArchiveExecDeps")

# Flags to apply to decompress the various types of archives.
_TAR_FLAGS = {
    "tar": [],
    "tar.bz2": ["-j"],
    "tar.gz": ["-z"],
    "tar.xz": ["-J"],
    "tar.zst": ["--use-compress-program=unzstd"],
}

_ARCHIVE_EXTS = _TAR_FLAGS.keys() + [
    "zip",
]

def _url_path(url: str) -> str:
    if "?" in url:
        return url.split("?")[0]
    else:
        return url

def _type_from_url(url: str) -> [str, None]:
    url_path = _url_path(url)
    for filename_ext in _ARCHIVE_EXTS:
        if url_path.endswith("." + filename_ext):
            return filename_ext
    return None

def archive_type(url_or_path: str, typ: str | None) -> str:
    if typ == None:
        typ = value_or(_type_from_url(url_or_path), "tar.gz")
    if typ not in _ARCHIVE_EXTS:
        fail("unsupported archive type: {}".format(typ))
    return typ

# Returns a two-element tuple:
#
# 1. The cmd_args with the unarchive command
# 2. A bool indicating whether the prefix still needs to be stripped (in cases where the tool used to uncompress does not support this feature).
def _unarchive_cmd(ext_type: str, exec_is_windows: bool, archive: Artifact, strip_prefix: [str, None]) -> (cmd_args, bool):
    if exec_is_windows:
        # So many hacks.
        if ext_type == "tar.zst":
            # tar that ships with windows is bsdtar
            # bsdtar seems to not properly interop with zstd and hangs instead of
            # exiting with an error. Manually decompressing with zstd and piping to
            # tar seems to work fine though.
            return cmd_args(
                "zstd",
                "-d",
                archive,
                "--stdout",
                "|",
                "%WINDIR%\\System32\\tar.exe",
                "-x",
                "-P",
                "-f",
                "-",
                _tar_strip_prefix_flags(strip_prefix),
            ), False
        elif ext_type == "zip":
            # unzip and zip are not cli commands available on windows. however, the
            # bsdtar that ships with windows has builtin support for zip
            return cmd_args(
                "%WINDIR%\\System32\\tar.exe",
                "-x",
                "-P",
                "-f",
                archive,
                _tar_strip_prefix_flags(strip_prefix),
            ), False

        # Else hope for the best

    if ext_type in _TAR_FLAGS:
        os_flags = (
            [
                # buck-out is a symlink with EdenFS, and tar on Windows doesn't like it,
                # and needs -P flag to allow operations with symlinks
                "-P",
            ]
            if exec_is_windows
            else []
        )
        return cmd_args(
            "tar",
            _TAR_FLAGS[ext_type],
            os_flags,
            "-x",
            "-f",
            archive,
            _tar_strip_prefix_flags(strip_prefix),
        ), False
    elif ext_type == "zip":
        # gnutar does not intrinsically support zip
        return cmd_args(archive, format = "unzip {}"), bool(strip_prefix)
    else:
        fail()

def _tar_strip_prefix_flags(strip_prefix: [str, None]) -> list[str]:
    if strip_prefix:
        # count nonempty path components in the prefix
        count = len(filter(lambda c: c != "", strip_prefix.split("/")))
        return ["--strip-components=" + str(count), strip_prefix]
    return []

def _finish_sub_targets(output: Artifact, sub_targets: list[str] | dict[str, list[str]]):
    if type(sub_targets) == type([]):
        return {path: [DefaultInfo(default_output = output.project(path))] for path in sub_targets}
    elif type(sub_targets) == type({}):
        return {name: [DefaultInfo(default_outputs = [output.project(path) for path in paths])] for name, paths in sub_targets.items()}
    else:
        fail("sub_targets must be a list or dict")

# The shell-free unpack. The generated `.sh` / `.bat` script exists only to
# `mkdir` + `cd` before tar runs, and the `cd` is what ties the Windows half
# to backslashes (cmd.exe rejects `cd a/b/c`). tar takes its destination as
# an argument instead (`-C`), spelled the same by GNU tar and bsdtar, so the
# argv is byte-identical on every execution platform. The one thing tar will
# not do is create the `-C` directory, and buck2 creates only the *parent* of
# a declared output -- so the extraction output is declared as
# `<tmp>/<strip_prefix>`: buck2 creates `<tmp>`, tar creates `<strip_prefix>`
# inside it, and a native copy_dir renames it to the requested output name
# (the same shape the zip path below uses when the tool cannot strip).
def _unarchive_tar_shell_free(
        ctx: AnalysisContext,
        archive: Artifact,
        output_name: str,
        ext_type: str,
        strip_prefix: str,
        prefer_local: bool,
        exec_matches_target: bool,
        sub_targets: list[str] | dict[str, list[str]],
        has_content_based_path: bool):
    prefix = strip_prefix.strip("/")
    expect("/" not in prefix, "shell-free unpack expects a single-component strip_prefix: {}".format(strip_prefix))
    extracted = ctx.actions.declare_output(output_name + "_tmp", prefix, dir = True, has_content_based_path = False)
    ctx.actions.run(
        cmd_args(
            "tar",
            _TAR_FLAGS[ext_type],
            "-x",
            "-f",
            archive,
            "-C",
            cmd_args(extracted.as_output(), parent = 1),
            prefix,
        ),
        category = "http_archive",
        identifier = output_name,
        prefer_local = prefer_local,
        # Publish only when this executor's OS is the only one that can mint
        # this action's digest -- i.e. when the target configuration's OS is
        # the executor's own. Hosts describe an identical tree differently
        # (NTFS has no mode bit, so buck2's Windows executor marks every
        # extension-less file executable in the directory digest), and the
        # configuration's OS constraint is inside the unpack's argv, so a
        # host-native unpack is unreachable by any other OS's executor and is
        # safe to publish. A cross-OS unpack is not: there its digest collides
        # with the native producer's, and the two disagree about the tree.
        # Consuming stays on either way. What still differs between an entry
        # authored by one OS and the same tree authored by another is the
        # executable flag on extension-less files, which matters only to a
        # consumer that executes a file straight out of the tree.
        allow_cache_upload = exec_matches_target,
    )
    output = ctx.actions.copy_dir(output_name, extracted, has_content_based_path = has_content_based_path)
    return output, _finish_sub_targets(output, sub_targets)

def unarchive(
    ctx: AnalysisContext,
    archive: Artifact,
    output_name: str,
    ext_type,
    excludes,
    strip_prefix,
    exec_deps: HttpArchiveExecDeps,
    prefer_local: bool,
    sub_targets: list[str] | dict[str, list[str]],
    has_content_based_path: bool = False,
):
    exec_os = exec_deps.exec_os_type[OsLookup].os
    exec_is_windows = exec_os == Os("windows")
    exec_matches_target = exec_os == ctx.attrs._target_os_type[OsLookup].os

    if ext_type in _TAR_FLAGS and strip_prefix and not excludes:
        return _unarchive_tar_shell_free(ctx, archive, output_name, ext_type, strip_prefix, prefer_local, exec_matches_target, sub_targets, has_content_based_path)

    if exec_is_windows:
        ext = "bat"
        mkdir = "md {}"
        interpreter = []
        first_param = "%1"
    else:
        ext = "sh"
        mkdir = "mkdir -p {}"
        interpreter = ["/bin/sh"]
        first_param = '"$1"'

    # Unpack archive to output directory.
    exclude_flags = []
    exclude_hidden = []
    if excludes:
        tar_flags = _TAR_FLAGS.get(ext_type)
        expect(tar_flags != None, "excludes not supported for non-tar archives")

        # Tar excludes files using globs, but we take regexes, so we need to
        # apply our regexes onto the file listing and produce an exclusion list
        # that just has strings.
        exclusions = ctx.actions.declare_output(output_name + "_exclusions", has_content_based_path = False)
        contents = ctx.actions.declare_output(output_name + "_contents", has_content_based_path = False)
        tar_script, _ = ctx.actions.write(
            "{}_listing.{}".format(output_name, ext),
            [
                cmd_args(
                    archive,
                    format = "tar --list " + " ".join(tar_flags) + " -f {} > " + first_param,
                )
            ],
            is_executable = True,
            allow_args = True,
            has_content_based_path = False,
        )
        ctx.actions.run(
            cmd_args(interpreter + [tar_script, contents.as_output()], hidden = [archive]),
            category = "process_exclusions",
        )

        def create_exclusion_list(ctx: AnalysisContext, artifacts, outputs):
            files = artifacts[contents].read_string().splitlines()
            exclusion_list = []
            exclude_regexen = [regex(e) for e in excludes]
            for f in files:
                for exclusion in exclude_regexen:
                    if exclusion.match(f):
                        exclusion_list.append(f)
                        break
            ctx.actions.write(outputs[exclusions], "\n".join(exclusion_list))

        ctx.actions.dynamic_output(
            dynamic = [contents],
            inputs = [],
            outputs = [exclusions.as_output()],
            f = create_exclusion_list,
        )

        exclude_flags.append(cmd_args(exclusions, format = "--exclude-from={}"))
        exclude_hidden.append(exclusions)

    unarchive_cmd, needs_strip_prefix = _unarchive_cmd(ext_type, exec_is_windows, archive, strip_prefix)

    output = ctx.actions.declare_output(output_name, dir = True, has_content_based_path = has_content_based_path)
    script_output = ctx.actions.declare_output(output_name + "_tmp", dir = True, has_content_based_path = False) if needs_strip_prefix else output

    script, _ = ctx.actions.write(
        "{}_unpack.{}".format(output_name, ext),
        [
            cmd_args(script_output.as_output(), format = mkdir),
            cmd_args(script_output.as_output(), format = "cd {}"),
            cmd_args([unarchive_cmd] + exclude_flags, delimiter = " ", relative_to = script_output.as_output()),
        ],
        is_executable = True,
        allow_args = True,
        has_content_based_path = False,
    )

    ctx.actions.run(
        cmd_args(
            interpreter + [script],
            hidden = exclude_hidden + [archive, script_output.as_output()],
        ),
        category = "http_archive",
        identifier = output_name,
        prefer_local = prefer_local,
    )

    if needs_strip_prefix:
        ctx.actions.copy_dir(output.as_output(), script_output.project(strip_prefix), has_content_based_path = has_content_based_path)

    if type(sub_targets) == type([]):
        sub_targets = {path: [DefaultInfo(default_output = output.project(path))] for path in sub_targets}
    elif type(sub_targets) == type({}):
        sub_targets = {name: [DefaultInfo(default_outputs = [output.project(path) for path in paths])] for name, paths in sub_targets.items()}
    else:
        fail("sub_targets must be a list or dict")

    return output, sub_targets
