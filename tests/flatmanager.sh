#!/bin/sh

set -e

top_dir="$(pwd)"

checkcmd() {
    if ! command -v "$1" > /dev/null 2>&1; then
        echo "$1 not found"
        exit 1
    fi
}

clean_up() {
    cd "tests/repo/min_success_metadata/gui-app" || exit
    echo "Deleting tests/repo/min_success_metadata/gui-app/{builddir, repo, .flatpak-builder}"
    rm -rf "builddir" "repo" ".flatpak-builder"
}

checkcmd "python"
checkcmd "gzip"
checkcmd "jq"
checkcmd "xmlstarlet"
checkcmd "git"
checkcmd "flatpak-builder" 
checkcmd "flatpak"
checkcmd "ostree"

if [ "$GITHUB_ACTIONS" = "true" ]; then
	checkcmd "dbus-run-session"
fi

if [ "$(git rev-parse --show-toplevel 2>/dev/null)" != "$(pwd)" ]; then
    echo "Abort. Not running from root of git repository."
    exit 1
fi

arch="$(flatpak --default-arch)"

files="docker/rewrite-manifest.py docker/flatpak-builder-lint-deps.json tests/repo/min_success_metadata/gui-app/org.flathub.gui.yaml tests/test_httpserver.py"
for item in ${files}; do
	if [ ! -f "$item" ]; then
		echo "$item does not exist."
		exit 1
	fi
done

if [ -z "$GITHUB_ACTIONS" ]; then
	echo "Not inside GitHub CI. Trying to build org.flatpak.Builder//localtest"
	flatpak remote-add --user --if-not-exists flathub https://flathub.org/repo/flathub.flatpakrepo

	if [ "$NO_CLEAN_UP" != "1" ]; then
		echo "Deleting build/org.flatpak.Builder"
		rm -rf build/org.flatpak.Builder
	fi

	if [ ! -d "build/org.flatpak.Builder" ]; then
		git clone --depth=1 --branch master --recursive --single-branch https://github.com/flathub/org.flatpak.Builder.git build/org.flatpak.Builder
	fi

	cd build && python3 ../docker/rewrite-manifest.py && cd org.flatpak.Builder || exit
	rm -v flatpak-builder-lint-deps.json && cp -v ../../docker/flatpak-builder-lint-deps.json .
	git config protocol.file.allow always
	flatpak-builder --user --force-clean --repo=repo --install-deps-from=flathub --default-branch=localtest --ccache --install builddir org.flatpak.Builder.json
fi

if [ ! "$(flatpak info -r org.flatpak.Builder//localtest)" ]; then
	echo "Did not find org.flatpak.Builder//localtest installed"
	exit 1
fi

cd "$top_dir" || exit
rm -vf nohup.out server.pid
nohup python tests/test_httpserver.py &
sleep 5

if [ "$NO_CLEAN_UP" != "1" ]; then
	clean_up
fi

cd "tests/repo/min_success_metadata/gui-app" || true
if [ "$GITHUB_ACTIONS" = "true" ]; then
	dbus-run-session flatpak run org.flatpak.Builder//localtest --verbose --user --force-clean --repo=repo --mirror-screenshots-url=https://dl.flathub.org/media --install-deps-from=flathub --ccache builddir org.flathub.gui.yaml
else
	flatpak run org.flatpak.Builder//localtest --verbose --user --force-clean --repo=repo --mirror-screenshots-url=https://dl.flathub.org/media --install-deps-from=flathub --ccache builddir org.flathub.gui.yaml
fi

mkdir -p builddir/files/share/app-info/media
ostree commit --repo=repo --canonical-permissions --branch=screenshots/"${arch}" builddir/files/share/app-info/media
export FLAT_MANAGER_BUILD_ID=0 FLAT_MANAGER_URL=http://localhost:9001 FLAT_MANAGER_TOKEN=foo
mkdir -p repo/appstream/"${arch}"
mv -v builddir/files/share/app-info/xmls/org.flathub.gui.xml.gz repo/appstream/"${arch}"/appstream.xml.gz

tests1_run="yes"
errors1="$(flatpak run --command=flatpak-builder-lint org.flatpak.Builder//localtest --exceptions repo repo|jq -r '.errors|.[]'|xargs)"
if [ "${errors1}" = "appstream-no-flathub-manifest-key" ]; then
	echo "Test 1: PASS ✅"
	test1_code="test_passed"
else
	echo "Test 1: FAIL, $errors1 🚨🚨"
	test1_code="test_failed"
fi

gzip -df repo/appstream/"${arch}"/appstream.xml.gz || true
xmlstarlet ed --subnode "/components/component" --type elem -n custom --subnode "/components/component/custom" --type elem -n value -v "https://raw.githubusercontent.com/flathub-infra/flatpak-builder-lint/240fe03919ed087b24d941898cca21497de0fa49/tests/repo/min_success_metadata/gui-app/org.flathub.gui.yaml" repo/appstream/"${arch}"/appstream.xml|xmlstarlet ed --insert //custom/value --type attr -n key -v flathub::manifest >> repo/appstream/"${arch}"/appstream-out.xml
rm -vf repo/appstream/"${arch}"/appstream.xml  repo/appstream/"${arch}"/appstream.xml.gz
mv -v repo/appstream/"${arch}"/appstream-out.xml repo/appstream/"${arch}"/appstream.xml
gzip repo/appstream/"${arch}"/appstream.xml || true

if flatpak run --command=flatpak-builder-lint org.flatpak.Builder//localtest --exceptions repo repo; then
	tests2_run="yes" && echo "Test 2: PASS ✅" && test2_code="test_passed"
else
	echo "Test 2: FAIL 🚨🚨" && test2_code="test_failed"
fi

gzip -df repo/appstream/"${arch}"/appstream.xml.gz || true
sed -i 's|https://raw.githubusercontent.com/flathub-infra/flatpak-builder-lint/240fe03919ed087b24d941898cca21497de0fa49/tests/repo/min_success_metadata/gui-app/org.flathub.gui.yaml|https://raw.githubusercontent.com/flathub-infra/wwwwwwwwww/240fe03919ed087b24d941898cca21497de0fa49/tests/repo/min_success_metadata/gui-app/org.flathub.yaml|g' repo/appstream/"${arch}"/appstream.xml
gzip repo/appstream/"${arch}"/appstream.xml || true

tests3_run="yes"
errors3="$(flatpak run --command=flatpak-builder-lint org.flatpak.Builder//localtest --exceptions repo repo|jq -r '.errors|.[]'|xargs)"
if [ "${errors3}" = "appstream-flathub-manifest-url-not-reachable" ]; then
	echo "Test 3: PASS ✅"
	test3_code="test_passed"
else
	echo "Test 3: FAIL, $errors3 🚨🚨"
	test3_code="test_failed"
fi

cd "$top_dir" || exit
python tests/test_httpserver.py --stop

if [ -z "$GITHUB_ACTIONS" ]; then
	flatpak remove -y --noninteractive org.flatpak.Builder//localtest
fi

rm -vf nohup.out server.pid

if [ "$NO_CLEAN_UP" != "1" ]; then
	clean_up
fi

unset FLAT_MANAGER_BUILD_ID FLAT_MANAGER_URL FLAT_MANAGER_TOKEN

if [ -z "${tests1_run}" ] || [ -z "${tests2_run}" ] || [ -z "${tests3_run}" ] ||
   [ "${test1_code}" = "test_failed" ] || [ "${test2_code}" = "test_failed" ] ||
   [ "${test3_code}" = "test_failed" ] || [ -z "${test1_code}" ] ||
   [ -z "${test2_code}" ] || [ -z "${test3_code}" ]; then
    echo "Tests failed 🚨🚨"
    exit 1
fi
