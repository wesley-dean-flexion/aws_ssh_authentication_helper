#!/usr/bin/env bash

## @file aws_ssh_authentication_helper.bash
## @brief allow users to authenticate via SSH public keys in AWS Code Commit
## @details
## AWS's Code Commit service allows users to associate SSH keys with their
## AWS accounts.  This tool allows a system to authenticate incoming SSH
## connections using the public portion of users' SSH keys from AWS Code
## Commit.
##
## The users' public keys do not need to be synchronized to the local system
## in advance -- this helper acquires the public portions of the keys
## on-demand and in real-time.  As a result, changes made in AWS Code Commit
## (e.g., the user uploads a new key, an administrator disables a key, etc.)
## are reflected immediately.
##
## However, this also necessitates a connection to AWS's APIs; if they're
## unavailable (e.g., there's an outage), new connections will not authenticate
## even if the user has already logged in (i.e., the public keys are not
## saved to users ~/.ssh/authorized_keys).
##
## Additionally, when the user attempts to connect, an AWS IAM group may be
## provided; if so, the tool will verify that the user exists in that group
## before permitting authentication.
##
## When users attempt to connect, this tool can create their accounts
## automatically.  Accounts will only be created if the username matches
## an AWS IAM user.  Moreover, if an AWS IAM group is provided, they will
## only be created if that AWS IAM user exists in that AWS IAM group.  This
## functionality is enabled by default but may be disabled via the
## 'create_user' environment variable (set it to "false" or "no").
##
## The tool also supports group management in that when users attempt to
## authenticate, they can be automatically added to a local (non-IAM) group.
## If the group doesn't exist, it will be created.  By default, this group
## is 'users' but that can be changed via environment variable (local_group).
##
## The adding of users to groups, while it takes place at authentication
## time, is not restricted to only new users being created for the first
## time.  That is, if the local_group setting is updated and a previously
## seen user attempts to login, they will be added to that group.
##
## When a user attempts to authenticate and either they do not belong to
## the required AWS IAM group or there is no corresponding AWS IAM user
## account, their local account can be removed.  This functionality is
## disabled by default but can be enabled via an environment variable
## (remove_user).  Regardless of that environment variable, users who
## do not have an enabled AWS IAM user account or are not in a specified
## AWS IAM group will be denied authentication.
##
## It's notable that changes made in AWS only affect new connections;
## that is, if a user is already logged in and then their AWS IAM
## account is disabled, their connection won't be dropped, interrupted,
## etc..  Manual intervention would be required to terminate current,
## active sessions.
##
## Environment variables:
##
## * local_group: the name of the local group users to which users
##   should be added (default = 'users')
##
## * create_user: whether or not to create accounts for previously
##   unseen users when they attempt to connect (default = true)
##
## * remove_user: whether or not to delete accounts disabled or
##   removed from the AWS side when they attempt to connect (default = false)
##
## * create_group: whether or not to create the local_group when the
##   user attempts to login (default = true)
##
## * manage_group: wheether or not to add users to the local_group when
##   they attempt to login (default = true)
##
## @author Wes Dean <wdean@flexion.us>

## @fn is_true()
## @brief if we're passed a true value, return 0 (True)
## @details
## True values start with a 0, the letters T or Y (True or Yes),
## or the number 0.  Anything else returns 1 (False).  Leading
## spaces and case are ignored.
##
## The number '0' is considered True because in Bash, 0s are
## considered True and non-zeros are considered False.
## @param string the string to evaluate
## @retval 0 (True) if the string is considered "true"
## @retval 1 (False) if the string is not considered "true"
## @par Example
## @code
## if is_true "Yes" ; then echo "Yay" ; else echo "Booooo" ; fi
## @endcode
is_true() {
  [[ "$1" =~ ^[[:space:]]*[TtYy0] ]]
}

## @fn is_false()
## @brief if we're passed a false falue, return 1 (False)
## @details
## This is like is_true() but will only return a true value if
## the string passed starts with the letters F or N (False or No),
## of the number 1.  Anything else returns a 1 (False).  Leading
## spaces and case are ignored.
##
## The decision was made to look for specific patterns and not
## simply return '! is_true()'.  For example, suppose the user
## passes the string 'help'; this string is not true, but it's
## also not false.  Otherwise, this functions just like is_true()
## but with a different pattern.  Caveat emptor.
## @param string the string to evaludate
## @retval 0 (True) if the string is considered "false"
## @retval 1 (False) if the string is not considered "false"
## @par Example
## @code
## is_false "$response" && exit 1
## @endcode
is_false() {
  [[ "$1" =~ ^[[:space:]]*[FfNn1] ]]
}


## @fn create_local_group()
## @brief if we're allowed, create a local group
## @details
## If we're allowed to create groups (via $create_group) and
## the group doesn't exist locally, then create it.
## @param local_group the name of the group to create
## @param local_gid the GID of the group to create
## @retval 0 (True) if the group was created or it already existed
## @retval 1 (False) if the group could not be created
## @par Example
## @code
## create_local_group "sshusers" 1003
## @endcode
create_local_group() {
  local local_group="${1?No group provided}"
  local local_gid="${2?No GID provided}"
  if is_true "$create_group" \
  && [ -n "$local_group" ] \
  && is_false "$local_group_exists" ; then
    groupadd -g "$local_gid" "$local_group" || return 1
  fi

  return 0
}


## @fn add_user_to_local_group()
## @brief if we're allowed to manage groups, adds user to a local group
## @details
## This does exactly what it says.  Permission via $manage_group.
## @param username the username to add to the group
## @param local_group the group to which the user should be added
## @retval 0 (True) if the user was added or they were already in the group
## @retval 1 (False) if the user couldn't be added
## @par Example
## @code
## add_user_to_local_group "wes" "sshusers" || exit 1
## @endcode
add_user_to_local_group() {
  local username="${1?No username provided}"
  local local_group="${2?No group name provided}"

  if is_true "$manage_group" \
  && [ -n "$local_group" ] ; then
    adduser "$username" "$local_group" > /dev/null || return 1
  fi

  return 0
}


## @fn create_local_user()
## @brief if we're allowed to create a user, create the user
## @details
## This will create a user if we're allowed to create users if
## we're allowed (via create_user), the user exists remotely,
## and the user does NOT exist locally.
## @param username the username to create locally
## @retval 0 (True) if the user was created or they already existed
## @retval 1 (False) if the user could not be created
## @par Example
## @code
## create_local_user "wes" || exit 1
## @endcode
create_local_user() {
  local username="${1?No username provided}"
  if is_true "$create_user" \
  && is_true "$remote_user_exists" \
  && is_false "$local_user_exists" ; then
    useradd -u "$numeric_uid" -m  "$username" > /dev/null || return 1
  fi

  return 0
}


# @fn remove_local_user()
## @brief if we're allowed to remove a user, remove the user
## @details
## This will remove a user IF the user exists both locally AND
## remotely, plus we're given permission (via remote_user).
##
## When removing the user, the user's home directory and
## associated spool files (cron, mail, etc.) will be removed
## first, then the user will be removed from the passwd
## database.
##
## This really isn't necessary for authentication purposes as
## if the user doesn't exist remotely (i.e., they're not in
## the remote group to check), they won't be able to login.
## It's really just for cleaning up after the user is gone. If
## space isn't a problem (cost, quota, etc.), it's recommended
## to leave this disabled) for name/id consistency mapping
## reasons.
## @param username the username to remove
## @retval 0 (True) if we removed the user or we didn't need to
## @retval 1 (False) if we were unable to remove the user
## @par Example
## @code
## remove_local_user "lastguy"
## @endcode
remove_local_user() {
  local username="${1?No username provided}"
  if is_true "$remove_user" \
  && is_true "$remote_user_exists" \
  && is_true "$local_user_exists" ; then
    deluser -r "$username" || return 1
  fi

  return 0
}


## @fn hex_to_dec()
## @brief convert a hexadecimal number (base 16) to decimal (base 10)
## @details
## Yes, printf and $(( )) can be used to do this.  However, we use
## bc because the hexadecimal numbers returned by sha1sum are way too
## large for the builtins and they overflow.  Boo.  Also, bc is pedantic
## about the case of the hexadecimal digits, so we use tr to make sure
## they're capitalized.  Work.
##
## The decimal (base 10) result is written to STDOUT.
## @param in the hexadecimal number to convert
## @retval 0 (True) if bc was happy
## @retval 1 (False) if bc decided to throw another fit
## @par Example
## @code
## echo "DEADBEEF in decimal is $(hex_to_dec "DEADBEEF")"
## @endcode
hex_to_dec() {
  in="${1?No input provided}"

  echo "scale=0; ibase=16; obase=10; $(echo "$in" | tr '[:lower:]' '[:upper:]')" | bc
}


## @fn name_to_id()
## @brief convert a user/group name, create a uid/gid from it
## @details
## We need to semi-reliably create users and groups whose
## uids and gids are consistent across multiple systems.  So,
## to generate an id, we hash the name that was provided and
## convert that hash into base-10 numbers (the hashes are hex)
## that we can use.
##
## To make sure we only use ids that are allowed for standard
## (non-system) use, we only allow ids that are between a
## minimum id and the maximum id using modulo.
##
## It's possible for there to be a collision between two
## names and a single id.  Therefore, when after we generate
## an id, we check to see if a name has already been mapped
## to that id on this system.  If so, we add one and try
## again up to max_tries (the third positional argument with a
## default value of 10) until we either find a match or we run
## out of tries at which point we fail.
##
## If we successfully find a name to id mapping, return it
## via STDOUT.
## @param string the string (user or group name) to use
## @param database the entity database (e.g., passwd or group) to query
## @param max_tries try this many times before returning failure (default = 10)
## @retval 0 (True) if we found a good mapping
## @retval 1 (False) if we could not find a good mapping
## @par Example
## @code
## uid="$(name_to_uid "wes" "passwd")" || exit 1
## @endcode
name_to_id() {
  string="${1?No string provided}"
  database="${2?No database provided}"
  max_tries="${3:-10}"

  local max_id=65535
  local min_id=2000
  local mod_id=$((max_id - min_id))

  local try=0

  while [ "$try" -lt "$max_tries" ] ; do
    local hash_string
    hash_string="$(echo -n "$string" | sha1sum | head -c40)"
    id="$(echo "$min_id + $(hex_to_dec "$hash_string") % $mod_id" | bc)"

    if check_id "$string" "$id" "$database" ; then
      echo "$id"
      return 0
    else
      (( try++ ))
    fi
  done

  return 1

}


## @fn check_id()
## @brief see if there's a collison between this name and this id
## @details
## This will check the local entity databases for the given name;
## if that name doesn't exist in the database, return true (if
## it doesn't exist, it can't be a collision by definition).  If
## the name does exist, look to see if it matches the given id; if
## so, return true.  If the name exists but it does NOT match the
## given id, we have a problem, so return false.
## @param name the entity name to check
## @param id the id the entity is expected to have
## @param database the database to query
## @retval 0 (True) if the name/id is good to use
## @retval 1 (False) if the name/id does NOT match
## @par Example
## @code
## if check_id "wes" 1000 passwd ; then echo "Cool" ; fi
## @endcode
check_id() {
  name="${1?No name provided}"
  id="${2?No id provided}"
  database="${3?No database provided}"

  if ! output="$(getent "$database" "$name")" ; then
    return 0 # true -- if it doesn't exist yet, we're good
  else

    if [[ "$output" =~ :${id}: ]] ; then
      return 0 # if the name matches the id, we're good
    else
      return 1 # if the name doesn't match the id, something's wrong
    fi
  fi
}


username="${1?No username provided}"

local_group="${local_group:-users}"
local_user_exists="$(getent passwd "$username" > /dev/null ; echo "$?")"
local_group_exists="$(getent group "$local_group" > /dev/null ; echo "$?")"

remote_group="${remote_group:-}"
remote_user_exists=1 # false (will check later)
remote_group_exists=1 # false (will check later)

create_user="${create_user:-true}"
remove_user="${remove_user:-false}"
create_group="${create_group:-true}"
manage_group="${manage_group:-true}"

config_file="${config_file:-/etc/aws_ssh_authentication_helper.conf}"

numeric_uid="$(name_to_id "$username" "passwd" || exit 1)"
numeric_gid="$(name_to_id "$local_group" "group" || exit 1)"

if [ -e "${config_file}" ] ; then
  #shellcheck disable=SC1090
  . "${config_file}"
fi

if [ -n "${remote_group}" ] ; then

  remote_group_exists="$(aws iam get-group --group-name "$remote_group" > /dev/null 2>&1 ; echo $?)"

  if is_true "$remote_group_exists" ; then
    if ! aws iam list-groups-for-user --user-name "${username}" --output text --query "Groups[?GroupName=='${remote_group}'].GroupName" | grep -q "${remote_group}" ; then
      remove_local_user "$username" ; exit 1
    fi
  fi
fi

for key_id in $(aws iam list-ssh-public-keys --user-name "${username}" --query "SSHPublicKeys[?Status=='Active'].SSHPublicKeyId" --output text) ; do
  aws iam get-ssh-public-key --user-name "${username}" --ssh-public-key-id "${key_id}" --encoding SSH --query "SSHPublicKey.SSHPublicKeyBody" --output text
  remote_user_exists=0 # true
done

create_local_user "$username" "$numeric_uid"
create_local_group "$local_group" "$numeric_gid"
add_user_to_group "$username" "$local_group"