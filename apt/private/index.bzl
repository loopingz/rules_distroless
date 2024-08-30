"apt-get"

load(":lockfile.bzl", "lockfile")

# header template for packages.bzl file
_DEB_IMPORT_HEADER_TMPL = '''\
"""Generated by rules_distroless. DO NOT EDIT."""
load("@rules_distroless//apt/private:deb_import.bzl", "deb_import")

# buildifier: disable=function-docstring
def {}_packages():
'''

# deb_import template for packages.bzl file
_DEB_IMPORT_TMPL = '''\
    deb_import(
        name = "{name}",
        urls = {urls},
        sha256 = "{sha256}",
    )
'''

_BUILD_TMPL = """\
exports_files(glob(['packages.bzl']))

sh_binary(
    name = "lock",
    srcs = ["copy.sh"],
    data = ["lock.json"],
    tags = ["manual"],
    args = ["$(location :lock.json)"],
    visibility = ["//visibility:public"]
) 
"""

_COPY_SH_TMPL = """\
#!/usr/bin/env bash
set -o pipefail -o errexit -o nounset

lock=$(realpath $1)

cd $BUILD_WORKING_DIRECTORY

echo ''
echo 'Writing lockfile to {workspace_relative_path}' 
cp $lock {workspace_relative_path}

# Detect which file we wish the user to edit
if [ -e $BUILD_WORKSPACE_DIRECTORY/WORKSPACE ]; then
    wksp_file="WORKSPACE"
elif [ -e $BUILD_WORKSPACE_DIRECTORY/WORKSPACE.bazel ]; then
    wksp_file="WORKSPACE.bazel"
else
    echo>&2 "Error: neither WORKSPACE nor WORKSPACE.bazel file was found"
    exit 1
fi

# Detect a vendored buildozer binary in canonical location (tools/buildozer)
if [ -e $BUILD_WORKSPACE_DIRECTORY/tools/buildozer ]; then
    buildozer="tools/buildozer"
else
    # Assume it's on the $PATH
    buildozer="buildozer"
fi

if [[ "${{2:-}}" == "--autofix" ]]; then
    echo ''
    ${{buildozer}} 'set lock \"{label}\"' ${{wksp_file}}:{name}
else
    cat <<EOF
Run the following command to add the lockfile or pass --autofix flag to do it automatically.

   ${{buildozer}} 'set lock \"{label}\"' ${{wksp_file}}:{name}
EOF
fi
"""

def _deb_package_index_impl(rctx):
    lock_content = rctx.attr.lock_content
    package_template = rctx.read(rctx.attr.package_template)
    lockf = lockfile.from_json(rctx, lock_content if lock_content else rctx.read(rctx.attr.lock))

    package_defs = []

    if not lock_content:
        package_defs = [_DEB_IMPORT_HEADER_TMPL.format(rctx.attr.name)]

        if len(lockf.packages()) < 1:
            package_defs.append("   pass")

    for (package) in lockf.packages():
        package_key = lockfile.make_package_key(
            package["name"],
            package["version"],
            package["arch"],
        )

        if not lock_content:
            package_defs.append(
                _DEB_IMPORT_TMPL.format(
                    name = "%s_%s" % (rctx.attr.name, package_key),
                    package_name = package["name"],
                    urls = [package["url"]],
                    sha256 = package["sha256"],
                ),
            )

        repo_name = "%s%s_%s" % ("@" if lock_content else "", rctx.attr.name, package_key)

        rctx.file(
            "%s/%s/BUILD.bazel" % (package["name"], package["arch"]),
            package_template.format(
                target_name = package["arch"],
                src = '"@%s//:data"' % repo_name,
                deps = ",\n        ".join([
                    '"//%s/%s"' % (dep["name"], package["arch"])
                    for dep in package["dependencies"] if dep["name"] != package["name"]
                ]),
                urls = [package["url"]],
                name = package["name"],
                arch = package["arch"],
                sha256 = package["sha256"],
                repo_name = "%s" % repo_name,
            ),
        )

    locklabel = rctx.attr.manifest.relative(rctx.attr.manifest.name.replace(".yaml", ".lock.json"))
    rctx.file(
        "copy.sh",
        _COPY_SH_TMPL.format(
            # TODO: don't assume the canonical -> apparent repo mapping character, as it might change
            # https://bazelbuild.slack.com/archives/C014RARENH0/p1719237766005439
            # https://github.com/bazelbuild/bazel/issues/22865
            name = rctx.name.split("~")[-1],
            label = locklabel,
            workspace_relative_path = (("%s/" % locklabel.package) if locklabel.package else "") + locklabel.name,
        ),
        executable = True,
    )

    lockf.write("lock.json")
    rctx.file("packages.bzl", "\n".join(package_defs))
    rctx.file("BUILD.bazel", _BUILD_TMPL)

deb_package_index = repository_rule(
    implementation = _deb_package_index_impl,
    attrs = {
        "manifest": attr.label(mandatory = True),
        "lock": attr.label(),
        "package_template": attr.label(default = "//apt/private:package.BUILD.tmpl"),
        "lock_content": attr.string(doc = "INTERNAL: DO NOT USE"),
    },
)
