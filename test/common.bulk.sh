# Common setup for bulk test runs

# Strip away @DEFAULT if it is the default FLAVOR
fix_default_flavor() {
	local _originspec="$1"
	local var_return="$2"
	local _origin _flavor _flavors _default_flavor

	originspec_decode "${_originspec}" _origin '' _flavor
	[ -z "${_flavor}" ] && return 0
	hash_get origin-flavors "${_origin}" _flavors
	_default_flavor="${_flavors%% *}"
	[ "${_default_flavor}" = "${_flavor}" ] || return 0
	setvar "${var_return}" "${_origin}"
}

# Cache all pkgnames involved.  Being single-threaded this is trivial.
cache_pkgnames() {
	local originspec="$1"
	local origin dep_origin flavor flavors pkgname

	hash_get originspec-pkgname "${originspec}" pkgname && return 0

	originspec_decode "${originspec}" origin '' flavor

	port_var_fetch_originspec "${originspec}" \
	   PKGNAME pkgname \
	   FLAVORS flavors \
	    _PDEPS='${PKG_DEPENDS} ${EXTRACT_DEPENDS} ${PATCH_DEPENDS} ${FETCH_DEPENDS} ${BUILD_DEPENDS} ${LIB_DEPENDS} ${RUN_DEPENDS}' \
	    '${_PDEPS:C,([^:]*):([^:]*):?.*,\2,:C,^${PORTSDIR}/,,:O:u}' \
	    pdeps
	hash_set origin-flavors "${origin}" "${flavors}"
	fix_default_flavor "${originspec}" originspec
	hash_set originspec-pkgname "${originspec}" "${pkgname}"
	hash_set originspec-deps "${originspec}" "${pdeps}"
	# Record all known packages for comparing to the queue later.
	ALL_PKGNAMES="${ALL_PKGNAMES}${ALL_PKGNAMES:+ }${pkgname}"
	ALL_ORIGINS="${ALL_ORIGINS}${ALL_ORIGINS:+ }${originspec}"
	for dep_origin in ${pdeps}; do
		cache_pkgnames "${dep_origin}"
	done
	# Also cache all of the FLAVOR deps/PKGNAMES
	if [ -n "${flavor}" ]; then
		for flavor in ${flavors}; do
			# Don't recurse on the first flavor since we are it.
			[ "${flavor}" = "${flavors%% *}" ] && continue
			originspec_encode originspec "${origin}" '' "${flavor}"
			cache_pkgnames "${originspec}"
		done
	fi
}

expand_origin_flavors() {
	local origins="$1"
	local var_return="$2"
	local originspec origin flavor flavors _expanded

	for originspec in ${origins}; do
		originspec_decode "${originspec}" origin '' flavor
		hash_get origin-flavors "${origin}" flavors || flavors=
		if [ -n "${flavor}" ] || [ -z "${flavors}" ]; then
			_expanded="${_expanded}${_expanded:+ }${originspec}"
			continue
		fi
		# Add all FLAVORS in for this one
		for flavor in ${flavors}; do
			originspec_encode originspec "${origin}" '' "${flavor}"
			_expanded="${_expanded}${_expanded:+ }${originspec}"
		done
	done

	setvar "${var_return}" "${_expanded}"
}

list_all_deps() {
	local origins="$1"
	local var_return="$2"
	local originspec origin _out flavors deps
	local dep_originspec dep_origin dep_flavor dep_flavors
	# Don't list 'recursed' local or setvar won't work to parent

	[ "${var_return}" = recursed ] || _out=

	for originspec in ${origins}; do
		# If it's already in the list, nothing to do
		case "${_out}" in
			*\ ${originspec}\ *) continue ;;
		esac
		_out="${_out:- }${originspec} "
		originspec_decode "${originspec}" origin '' flavor
		flavors=
		[ -z "${flavor}" ] && \
		    hash_get origin-flavors "${origin}" flavors
		fix_default_flavor "${originspec}" originspec
		# Check all deps
		hash_get originspec-deps "${originspec}" deps || deps=
		for dep_originspec in ${deps}; do
			# If the dependency has flavors and is not
			# FLAVOR-specific, it needs to be changed to
			# depend on the default FLAVOR instead.
			originspec_decode "${dep_originspec}" dep_origin \
			    '' dep_flavor
			if [ -z "${dep_flavor}" ]; then
				hash_get origin-flavors \
				    "${dep_origin}" dep_flavors || \
				    dep_flavors=
				if [ -n "${dep_flavors}" ]; then
					# Change to default
					dep_flavor="${dep_flavors%% *}"
					originspec_encode dep_originspec \
					    "${dep_origin}" '' "${dep_flavor}"
				fi
			fi

			recursed=
			list_all_deps "${dep_originspec}" recursed
			_out="${recursed}"
		done
		# And all FLAVORS if needed
		if [ -n "${flavor}" ]; then
			orig_originspec="${originspec}"
			for flavor in ${flavors}; do
				originspec_encode originspec "${origin}" '' \
				    "${flavor}"
				recursed=
				list_all_deps "${originspec}" recursed
				_out="${recursed}"
			done
		fi
	done
	setvar "${var_return}" "${_out}"
}

assert_queued() {
	local dep="$1"
	local origins="$2"
	local tmp originspec origin flavor origins_expanded

	tmp="$(mktemp -t queued.${dep})"
	awk -v dep="${dep}" '$3 == dep' "${log}/.poudriere.ports.queued" \
	    > "${tmp}"
	# First fix the list to expand main port FLAVORS
	expand_origin_flavors "${origins}" origins_expanded
	# The queue does remove duplicates - do the same here
	origins_expanded="$(echo "${origins_expanded}" | tr ' ' '\n' | sort -u | tr '\n' ' ')"
	echo "Asserting that only '${origins_expanded}' are in the${dep:+ ${dep}} queue"
	for originspec in ${origins_expanded}; do
		originspec_decode "${originspec}" origin '' flavor
		fix_default_flavor "${originspec}" originspec
		hash_get originspec-pkgname "${originspec}" pkgname
		assert_not '' "${pkgname}" "PKGNAME needed for ${originspec}"
		echo "=> Asserting that ${origin} | ${pkgname} is${dep:+ dep=${dep}} in queue"
		# The queue does not list @FLAVORS for the origin, only PKGNAME
		# is FLAVOR-specific.
		awk -vpkgname="${pkgname}" -vorigin="${origin}" -vdep="${dep}" '
		    $1 == origin && $2 == pkgname && (dep == "" || $3 == dep) {
			print "==> " $0
			if (found == 1) {
				# A duplicate, no good.
				found = 0
				exit 1
			}
			found = 1
			next
		    }
		    $1 == origin && $2 == pkgname && dep != "" && $3 != dep {
			print "==> " $0
			found = 0
			exit 1
		    }
		    END { if (found != 1) exit 1 }
		' ${log}/.poudriere.ports.queued >&2
		assert 0 $? "${origin} | ${pkgname} should be queued${dep:+ with dep=${dep}}"
		# Remove the entry so we can assert later that nothing extra
		# is in the queue.
		cat "${tmp}" | \
		    awk -vpkgname="${pkgname}" -vorigin="${origin}" \
		    -vdep="${dep}" '
		    $1 == origin && $2 == pkgname && $3 == dep { next }
		    { print }
		' > "${tmp}.new"
		mv -f "${tmp}.new" "${tmp}"
	done
	echo "=> Asserting that nothing else is in the${dep:+ ${dep}} queue"
	cat "${tmp}" | sed -e 's,^,==> ,' >&2
	! [ -s "${tmp}" ]
	assert 0 $? "Queue should be empty"
	rm -f "${tmp}"
}

# Need to trim environment of anything that may taint our top-level port var
# fetching.
while read var; do
	unset ${var}
done <<-EOF
$(env | egrep '^(WITH_|PORT)')
EOF
export __MAKE_CONF=/dev/null
export SRCCONF=/dev/null
export SRC_ENV_CONF=/dev/null

. common.sh

assert_not "" "${LISTPORTS}" "LISTPORTS empty"
echo "Building: $(echo ${LISTPORTS})"

: ${BUILDNAME:=${0%.sh}}
POUDRIERE="${POUDRIEREPATH} -e /usr/local/etc"
ARCH=$(uname -p)
JAILNAME="poudriere-10${ARCH}"
JAIL_VERSION="10.3-RELEASE"
JAILMNT=$(${POUDRIERE} api "jget ${JAILNAME} mnt" 2>/dev/null || echo)
if [ -z "${JAILMNT}" ]; then
	echo "Setting up jail for testing..." >&2
	if ! ${POUDRIERE} jail -c -j "${JAILNAME}" \
	    -v "${JAIL_VERSION}" -a ${ARCH}; then
		echo "SKIP: Cannot setup jail with Poudriere" >&2
		exit 0
	fi
	JAILMNT=$(${POUDRIERE} api "jget ${JAILNAME} mnt" 2>/dev/null || echo)
	if [ -z "${JAILMNT}" ]; then
		echo "SKIP: Failed fetching mnt for new jail in Poudriere" >&2
		exit 0
	fi
	echo "Done setting up test jail" >&2
	echo >&2
fi

. ${SCRIPTPREFIX}/common.sh

PORTSDIR=${THISDIR}/ports
PTMNT="${PORTSDIR}"
: ${JAILNAME:=bulk}
: ${PTNAME:=test}
: ${SETNAME:=}
export PORT_DBDIR=/dev/null

set -e

# Import local ports tree
pset "${PTNAME}" mnt "${PTMNT}"
pset "${PTNAME}" method "-"

# Import jail
jset "${JAILNAME}" version "${JAIL_VERSION}"
jset "${JAILNAME}" timestamp $(clock -epoch)
jset "${JAILNAME}" arch "${ARCH}"
jset "${JAILNAME}" mnt "${JAILMNT}"
jset "${JAILNAME}" method "null"

MASTERNAME=${JAILNAME}-${PTNAME}${SETNAME:+-${SETNAME}}
_mastermnt MASTERMNT
export POUDRIERE_BUILD_TYPE=bulk
_log_path log

echo -n "Pruning previous logs..."
${POUDRIEREPATH} -e ${POUDRIERE_ETC} logclean -B "${BUILDNAME}" -ay >/dev/null
echo " done"
set +e

ALL_PKGNAMES=
ALL_ORIGINS=
for origin in ${LISTPORTS}; do
	cache_pkgnames "${origin}"
done
