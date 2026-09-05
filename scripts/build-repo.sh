#!/usr/bin/env bash

set -euo pipefail

LC_ALL=C
export LC_ALL

PUBLIC_BASE_URL="${PUBLIC_BASE_URL:-https://notfence.github.io/repo}"
PUBLIC_BASE_URL="${PUBLIC_BASE_URL%/}"

project_root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
manifest_dir="${project_root}/packages"
mode="build"

if [[ "${1:-}" == "--state" ]]; then
  mode="state"
  shift
fi

output_dir="${1:-${project_root}/public}"
output_dir="$(realpath -m -- "${output_dir}")"

case "${output_dir}" in
  "${project_root}/public"|"${project_root}/build/public") ;;
  *)
    echo "Refusing to replace output directory outside this repository: ${output_dir}" >&2
    exit 1
    ;;
esac

required_commands=(curl jq sha256sum)
if [[ "${mode}" == "build" ]]; then
  required_commands+=(bzip2 dpkg-deb gzip md5sum sha1sum stat)
fi

for command in "${required_commands[@]}"; do
  if ! command -v "${command}" >/dev/null 2>&1; then
    echo "Required command is missing: ${command}" >&2
    exit 1
  fi
done

shopt -s nullglob
manifest_files=("${manifest_dir}"/*.json)
shopt -u nullglob

if (( ${#manifest_files[@]} == 0 )); then
  echo "No package manifests found in ${manifest_dir}" >&2
  exit 1
fi

temporary_dir="$(mktemp -d)"
trap 'rm -rf -- "${temporary_dir}"' EXIT

state_entries="${temporary_dir}/release-state"
architectures="${temporary_dir}/architectures"
touch "${state_entries}" "${architectures}"
declare -A seen_packages=()

if [[ "${mode}" == "build" ]]; then
  staging_dir="${temporary_dir}/public"
  packages_file="${staging_dir}/Packages"
  mkdir -p "${staging_dir}/debs" "${staging_dir}/depictions"
  cp -a "${project_root}/site/." "${staging_dir}/"
  : > "${packages_file}"
fi

github_api_get() {
  local url="$1"
  local destination="$2"
  local -a headers=(
    -H "Accept: application/vnd.github+json"
    -H "X-GitHub-Api-Version: 2022-11-28"
  )

  if [[ -n "${GITHUB_TOKEN:-}" ]]; then
    headers+=(-H "Authorization: Bearer ${GITHUB_TOKEN}")
  fi

  curl --fail --location --silent --show-error \
    --retry 3 --retry-all-errors \
    "${headers[@]}" \
    "${url}" \
    -o "${destination}"
}

manifest_value() {
  local manifest="$1"
  local key="$2"
  jq -er "${key} | select(type == \"string\" and length > 0)" "${manifest}"
}

validate_relative_path() {
  local path="$1"
  if [[ "${path}" == /* || "${path}" == *".."* ]]; then
    echo "Unsafe relative path in package manifest: ${path}" >&2
    exit 1
  fi
}

strip_direct_download() {
  awk '
    {
      line = $0
      sub(/\r$/, "", line)
      heading = tolower(line)
      gsub(/\*/, "", heading)
      if (heading ~ /^##+[[:space:]]+direct download[[:space:]]*$/) {
        exit
      }
      print line
    }
  '
}

write_package_control() {
  local deb_path="$1"
  dpkg-deb -f "${deb_path}" | awk '
    /^[^[:space:]][^:]*:/ {
      key = tolower(substr($0, 1, index($0, ":") - 1))
      skip = (key == "filename" || key == "size" || key == "md5sum" ||
              key == "sha1" || key == "sha256" || key == "icon" ||
              key == "homepage" || key == "depiction" ||
              key == "sileodepiction" || key == "native-depiction")
    }
    !skip { print }
  '
}

for manifest in "${manifest_files[@]}"; do
  source_repository="$(manifest_value "${manifest}" '.sourceRepository')"
  asset_name="$(manifest_value "${manifest}" '.assetName')"
  expected_package="$(manifest_value "${manifest}" '.package')"
  expected_architecture="$(manifest_value "${manifest}" '.architecture')"

  if [[ ! "${source_repository}" =~ ^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$ ]]; then
    echo "Invalid GitHub repository in ${manifest}: ${source_repository}" >&2
    exit 1
  fi
  if [[ ! "${asset_name}" =~ ^[A-Za-z0-9._+~-]+$ ]]; then
    echo "Asset name must not contain a path: ${asset_name}" >&2
    exit 1
  fi
  if [[ ! "${expected_package}" =~ ^[a-z0-9][a-z0-9+.-]+$ ]]; then
    echo "Invalid package identifier in ${manifest}: ${expected_package}" >&2
    exit 1
  fi
  if [[ ! "${expected_architecture}" =~ ^[A-Za-z0-9][A-Za-z0-9._-]+$ ]]; then
    echo "Invalid package architecture in ${manifest}: ${expected_architecture}" >&2
    exit 1
  fi

  if [[ -n "${seen_packages["${expected_package}"]+present}" ]]; then
    echo "Duplicate package manifest: ${expected_package}" >&2
    exit 1
  fi
  seen_packages["${expected_package}"]=1

  releases_json="${temporary_dir}/${expected_package}-releases.json"
  github_api_get \
    "https://api.github.com/repos/${source_repository}/releases?per_page=100" \
    "${releases_json}"

  release_json="${temporary_dir}/${expected_package}-release.json"
  if ! jq -ce '[.[] | select(.draft == false and .prerelease == false)][0]' \
    "${releases_json}" > "${release_json}"; then
    echo "No stable releases found for ${source_repository}" >&2
    exit 1
  fi

  release_tag="$(jq -er '.tag_name' "${release_json}")"
  release_asset="$(jq -c --arg name "${asset_name}" \
    'first(.assets[] | select(.name == $name)) // empty' "${release_json}")"

  if [[ -z "${release_asset}" ]]; then
    echo "Release ${source_repository}@${release_tag} has no ${asset_name} asset" >&2
    exit 1
  fi

  asset_id="$(jq -er '.id' <<<"${release_asset}")"
  release_history_state="$(
    jq -c \
      '[.[] | select(.draft == false and .prerelease == false)][0:5]
       | map({id, tag_name, updated_at})' \
      "${releases_json}" \
      | sha256sum \
      | awk '{print $1}'
  )"
  printf '%s\t%s\t%s\t%s\t%s\n' \
    "${expected_package}" "${source_repository}" "${release_tag}" "${asset_id}" "${release_history_state}" \
    >> "${state_entries}"

  if [[ "${mode}" == "state" ]]; then
    continue
  fi

  icon_path="$(manifest_value "${manifest}" '.icon')"
  package_icon="$(manifest_value "${manifest}" '.packageIcon')"
  depiction_path="$(manifest_value "${manifest}" '.depiction')"
  cydia_depiction_path="$(manifest_value "${manifest}" '.cydiaDepiction')"
  homepage="$(manifest_value "${manifest}" '.homepage')"
  details_description="$(manifest_value "${manifest}" '.description')"
  validate_relative_path "${icon_path}"
  validate_relative_path "${depiction_path}"
  validate_relative_path "${cydia_depiction_path}"

  if [[ "${homepage}" != https://* ]]; then
    echo "Package homepage must use HTTPS: ${homepage}" >&2
    exit 1
  fi
  if [[ "${package_icon}" != file:///* || "${package_icon}" == *".."* ]]; then
    echo "Cydia package icon must use a local file URI: ${package_icon}" >&2
    exit 1
  fi

  if [[ ! -f "${staging_dir}/${icon_path}" ]]; then
    echo "Package icon does not exist: ${icon_path}" >&2
    exit 1
  fi

  asset_url="$(jq -er '.browser_download_url' <<<"${release_asset}")"
  asset_digest="$(jq -r '.digest // empty' <<<"${release_asset}")"
  deb_path="${temporary_dir}/${asset_id}-${asset_name}"

  curl --fail --location --silent --show-error \
    --retry 3 --retry-all-errors \
    "${asset_url}" \
    -o "${deb_path}"

  if [[ "${asset_digest}" == sha256:* ]]; then
    expected_digest="${asset_digest#sha256:}"
    actual_digest="$(sha256sum "${deb_path}" | awk '{print $1}')"
    if [[ "${actual_digest}" != "${expected_digest}" ]]; then
      echo "SHA-256 mismatch for ${source_repository}@${release_tag}/${asset_name}" >&2
      exit 1
    fi
  fi

  package_name="$(dpkg-deb -f "${deb_path}" Package)"
  package_version="$(dpkg-deb -f "${deb_path}" Version)"
  package_architecture="$(dpkg-deb -f "${deb_path}" Architecture)"
  package_display_name="$(dpkg-deb -f "${deb_path}" Name 2>/dev/null || true)"

  if [[ "${package_name}" != "${expected_package}" ]]; then
    echo "Unexpected package name in ${asset_name}: ${package_name}" >&2
    exit 1
  fi
  if [[ "${package_architecture}" != "${expected_architecture}" ]]; then
    echo "Unexpected package architecture in ${asset_name}: ${package_architecture}" >&2
    exit 1
  fi
  if [[ -z "${package_version}" ]]; then
    echo "Package version is empty in ${asset_name}" >&2
    exit 1
  fi
  if [[ -z "${package_display_name}" ]]; then
    package_display_name="${package_name}"
  fi

  package_deb_dir="${staging_dir}/debs/${package_name}"
  package_deb_path="debs/${package_name}/${asset_name}"
  mkdir -p "${package_deb_dir}"
  install -m 0644 "${deb_path}" "${staging_dir}/${package_deb_path}"
  printf '%s\n' "${package_architecture}" >> "${architectures}"

  write_package_control "${deb_path}" >> "${packages_file}"
  printf 'Filename: %s\n' "${package_deb_path}" >> "${packages_file}"
  printf 'Size: %s\n' "$(stat -c '%s' "${deb_path}")" >> "${packages_file}"
  printf 'MD5sum: %s\n' "$(md5sum "${deb_path}" | awk '{print $1}')" >> "${packages_file}"
  printf 'SHA1: %s\n' "$(sha1sum "${deb_path}" | awk '{print $1}')" >> "${packages_file}"
  printf 'SHA256: %s\n' "$(sha256sum "${deb_path}" | awk '{print $1}')" >> "${packages_file}"
  printf 'Icon: %s\n' "${package_icon}" >> "${packages_file}"
  printf 'Homepage: %s\n' "${homepage}" >> "${packages_file}"
  printf 'Depiction: %s/%s\n' "${PUBLIC_BASE_URL}" "${cydia_depiction_path}" >> "${packages_file}"
  printf 'SileoDepiction: %s/%s\n' "${PUBLIC_BASE_URL}" "${depiction_path}" >> "${packages_file}"
  printf 'Native-Depiction: %s/%s\n\n' "${PUBLIC_BASE_URL}" "${depiction_path}" >> "${packages_file}"

  release_history='[]'
  while IFS= read -r release; do
    release_version="$(jq -r '.tag_name' <<<"${release}")"
    release_notes="$(jq -r '.body // empty' <<<"${release}" | strip_direct_download)"
    if [[ -z "${release_notes}" ]]; then
      release_notes="No changelog was provided for this release."
    fi
    release_history="$(
      jq -c \
        --arg version "${release_version}" \
        --arg notes "${release_notes}" \
        '. + [{version: $version, notes: $notes}]' \
        <<<"${release_history}"
    )"
  done < <(
    jq -c \
      '[.[] | select(.draft == false and .prerelease == false)][0:5][]' \
      "${releases_json}"
  )

  depiction_file="${staging_dir}/${depiction_path}"
  mkdir -p "$(dirname -- "${depiction_file}")"
  jq -n \
    --arg name "${package_display_name}" \
    --arg version "${package_version}" \
    --arg description "${details_description}" \
    --arg homepage "${homepage}" \
    --argjson releases "${release_history}" \
    -f "${project_root}/scripts/depiction.jq" > "${depiction_file}"

  cydia_depiction_file="${staging_dir}/${cydia_depiction_path}"
  mkdir -p "$(dirname -- "${cydia_depiction_file}")"
  jq -nr \
    --arg name "${package_display_name}" \
    --arg description "${details_description}" \
    --arg homepage "${homepage}" \
    --arg icon "${PUBLIC_BASE_URL}/${icon_path}" \
    --argjson releases "${release_history}" \
    -f "${project_root}/scripts/cydia-depiction.jq" > "${cydia_depiction_file}"

  echo "Built ${package_name} ${package_version} from ${source_repository}@${release_tag}"
done

release_state="$(sha256sum "${state_entries}" | awk '{print $1}')"
if [[ "${mode}" == "state" ]]; then
  printf '%s\n' "${release_state}"
  exit 0
fi

(
  cd "${staging_dir}"
  gzip -9n -c Packages > Packages.gz
  bzip2 -9c Packages > Packages.bz2
)

repository_architectures="$(sort -u "${architectures}" | paste -sd ' ' -)"
release_file="${staging_dir}/Release"
release_date="$(date -Ru)"

append_release_hashes() {
  local title="$1"
  local command="$2"
  printf '%s:\n' "${title}" >> "${release_file}"
  for metadata_file in Packages Packages.gz Packages.bz2; do
    printf ' %s %16s %s\n' \
      "$("${command}" "${staging_dir}/${metadata_file}" | awk '{print $1}')" \
      "$(stat -c '%s' "${staging_dir}/${metadata_file}")" \
      "${metadata_file}" >> "${release_file}"
  done
}

cat > "${release_file}" <<EOF
Origin: notfence's Repo
Label: notfence's Repo
Suite: stable
Codename: ios
Version: 1.0
Architectures: ${repository_architectures}
Components: main
Description: Package repository by notfence for Cydia and Sileo
Date: ${release_date}
EOF

append_release_hashes MD5Sum md5sum
append_release_hashes SHA1 sha1sum
append_release_hashes SHA256 sha256sum

printf '%s\n' "${release_state}" > "${staging_dir}/release-state"
touch "${staging_dir}/.nojekyll"

rm -rf -- "${output_dir}"
mv "${staging_dir}" "${output_dir}"

echo "Published ${#manifest_files[@]} package manifest(s)"
