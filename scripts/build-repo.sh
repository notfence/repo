#!/usr/bin/env bash

set -euo pipefail

SOURCE_REPOSITORY="${SOURCE_REPOSITORY:-notfence/vless-core-app}"
ASSET_NAME="${ASSET_NAME:-com.vlesscore.app_iphoneos-arm.deb}"
EXPECTED_PACKAGE="${EXPECTED_PACKAGE:-com.vlesscore.app}"
EXPECTED_ARCHITECTURE="${EXPECTED_ARCHITECTURE:-iphoneos-arm}"

project_root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
output_dir="${1:-${project_root}/public}"
output_dir="$(realpath -m -- "${output_dir}")"

case "${output_dir}" in
  "${project_root}/public"|"${project_root}/build/public") ;;
  *)
    echo "Refusing to replace output directory outside this repository: ${output_dir}" >&2
    exit 1
    ;;
esac

for command in curl jq dpkg-deb dpkg-scanpackages gzip bzip2 sha256sum sha1sum md5sum stat; do
  if ! command -v "${command}" >/dev/null 2>&1; then
    echo "Required command is missing: ${command}" >&2
    exit 1
  fi
done

temporary_dir="$(mktemp -d)"
trap 'rm -rf -- "${temporary_dir}"' EXIT

release_json="${temporary_dir}/release.json"
deb_path="${temporary_dir}/${ASSET_NAME}"

curl --fail --location --silent --show-error \
  --retry 3 --retry-all-errors \
  -H "Accept: application/vnd.github+json" \
  -H "X-GitHub-Api-Version: 2022-11-28" \
  "https://api.github.com/repos/${SOURCE_REPOSITORY}/releases/latest" \
  -o "${release_json}"

release_tag="$(jq -er '.tag_name' "${release_json}")"
release_asset="$(jq -cer --arg name "${ASSET_NAME}" \
  '.assets[] | select(.name == $name)' "${release_json}" | head -n 1)"

if [[ -z "${release_asset}" ]]; then
  echo "Release ${release_tag} has no ${ASSET_NAME} asset" >&2
  exit 1
fi

asset_id="$(jq -er '.id' <<<"${release_asset}")"
asset_url="$(jq -er '.browser_download_url' <<<"${release_asset}")"
asset_digest="$(jq -er '.digest // empty' <<<"${release_asset}" || true)"

curl --fail --location --silent --show-error \
  --retry 3 --retry-all-errors \
  "${asset_url}" \
  -o "${deb_path}"

if [[ "${asset_digest}" == sha256:* ]]; then
  expected_digest="${asset_digest#sha256:}"
  actual_digest="$(sha256sum "${deb_path}" | awk '{print $1}')"
  if [[ "${actual_digest}" != "${expected_digest}" ]]; then
    echo "SHA-256 mismatch for ${ASSET_NAME}" >&2
    exit 1
  fi
fi

package_name="$(dpkg-deb -f "${deb_path}" Package)"
package_version="$(dpkg-deb -f "${deb_path}" Version)"
package_architecture="$(dpkg-deb -f "${deb_path}" Architecture)"

if [[ "${package_name}" != "${EXPECTED_PACKAGE}" ]]; then
  echo "Unexpected package name: ${package_name}" >&2
  exit 1
fi

if [[ "${package_architecture}" != "${EXPECTED_ARCHITECTURE}" ]]; then
  echo "Unexpected package architecture: ${package_architecture}" >&2
  exit 1
fi

if [[ -z "${package_version}" ]]; then
  echo "Package version is empty" >&2
  exit 1
fi

rm -rf -- "${output_dir}"
mkdir -p -- "${output_dir}/debs"
install -m 0644 "${deb_path}" "${output_dir}/debs/${ASSET_NAME}"
install -m 0644 "${project_root}/site/index.html" "${output_dir}/index.html"

(
  cd "${output_dir}"
  dpkg-scanpackages -m debs > Packages
  gzip -9n -c Packages > Packages.gz
  bzip2 -9c Packages > Packages.bz2
)

release_file="${output_dir}/Release"
release_date="$(LC_ALL=C date -Ru)"

cat > "${release_file}" <<EOF
Origin: notfence
Label: notfence repository
Suite: stable
Codename: ios
Version: 1.0
Architectures: ${EXPECTED_ARCHITECTURE}
Components: main
Description: Package repository by notfence for Cydia and Sileo
Date: ${release_date}
MD5Sum:
EOF

for metadata_file in Packages Packages.gz Packages.bz2; do
  printf ' %s %16s %s\n' \
    "$(md5sum "${output_dir}/${metadata_file}" | awk '{print $1}')" \
    "$(stat -c '%s' "${output_dir}/${metadata_file}")" \
    "${metadata_file}" >> "${release_file}"
done

printf 'SHA1:\n' >> "${release_file}"
for metadata_file in Packages Packages.gz Packages.bz2; do
  printf ' %s %16s %s\n' \
    "$(sha1sum "${output_dir}/${metadata_file}" | awk '{print $1}')" \
    "$(stat -c '%s' "${output_dir}/${metadata_file}")" \
    "${metadata_file}" >> "${release_file}"
done

printf 'SHA256:\n' >> "${release_file}"
for metadata_file in Packages Packages.gz Packages.bz2; do
  printf ' %s %16s %s\n' \
    "$(sha256sum "${output_dir}/${metadata_file}" | awk '{print $1}')" \
    "$(stat -c '%s' "${output_dir}/${metadata_file}")" \
    "${metadata_file}" >> "${release_file}"
done

printf '%s\n' "${asset_id}" > "${output_dir}/release-asset-id"
printf '%s\n' "${release_tag}" > "${output_dir}/release-tag"
printf '%s\n' "${package_version}" > "${output_dir}/package-version"
touch "${output_dir}/.nojekyll"

echo "Built ${package_name} ${package_version} from ${release_tag} (asset ${asset_id})"
