#!/usr/bin/env bash
# Author: Luke Matarazzo
# Copyright (c) 2013, Luke Matarazzo
# All rights reserved.

if [ "$1" = "-h" -o "$1" = "--help" ]; then
	echo "Usage:  ./jail_maker [OPTION] [JAIL_PATH]"
	#echo "	./jail_maker [CONFIG_FILE]"
	echo "Note: must be run as root."
	echo "Create a jail environment to be used as in a chroot jail configuration."
	echo ""
	echo "Invoking the script without any parameters will enter the script in manual configuration mode in which it will prompt you on how to create the jail"
	echo "	-h, --help 	print this help information"
	echo "	-s, --secure 	configure a very secure jail with the bare minimum"
	echo "			of executables and libraries"
	echo
	echo "Remember: must be run as root to 100% successful. When script prompts for users, it creates their home directory in the jail and assumes they already exist as users on the system and gives them ownership of their home directories. If they don't yet exist, you will have to manually change the ownership of their home directories after the script runs."
fi

if [ "$USER" != "root" ]; then
	echo "Must run as root."
	exit 1
fi

sugJail="/var/jail"

copy_libraries(){ #copies libraries for a specific binary
	# iggy ld-linux* file as it is not shared one
	FILES=$(/usr/bin/ldd "$1" | /usr/bin/awk '{print $3}' | /bin/grep -ve '^(' | /bin/grep -ve '^$')

	#echo "Copying shared files/libs to $path..."
	for i in $FILES; do
		d=$(dirname "$i")
		[ ! -d "${path}$d" ] && /bin/mkdir -p "${path}$d"
		/bin/cp "$i" "${path}$d"
	done

	# copy /lib/ld-linux* or /lib64/ld-linux* to $path/$sldlsubdir
	# get ld-linux full file location 
	sldl=$(/usr/bin/ldd "$1" | /bin/grep 'ld-linux' | /usr/bin/awk '{print $1}')
	# now get sub-dir
	sldlsubdir=$(/usr/bin/dirname "$sldl")

	if [ ! -f "$path$sldl" ]; then
		/bin/cp "$sldl" "$path$sldlsubdir"
	fi
}

suggestJail(){ #suggest a valid jail that doesn't already exist
	sugJail="/var/jail"
	while [ -d "$sugJail" ]; do
		sugJail="/var/jail-$RANDOM"
	done
}

error_file=".jm_error"

#determine system editor
#this is dumb, fix it later
if [ -e /usr/bin/vim ]; then
	editor="vim"
elif [ -e /usr/bin/vi ]; then
	editor="vi"
elif [ -e /usr/bin/nano ]; then
	editor="nano"
elif [ -e /usr/bin/pico ]; then
	editor="pico"
elif [ -e /usr/bin/emacs ]; then
	editor="emacs"
fi

#find nologin shell
#fix this to use /bin/false if nologin not found
nologin=$(which nologin)
if [ "$nologin" = "" ]; then
	if [ -e "/sbin/nologin" ]; then
		nologin="/sbin/nologin"
	else
		nologin="/usr/sbin/nologin"
	fi
fi

if [ "$1" = "-s" -o "$1" = "--secure" ]; then
	shift
	if [ "$#" -ne 1 ]; then
		read -p "You did not enter a directory. Enter path of jail directory: " dir
		dir="${dir// /_}" #replace any spaces with underscores
	fi

	dir="$1"

	while [ -d "$dir" ]; do
		echo "That directory already exists. Please enter another location." >&2
		read -p "Enter path of jail directory: " dir
		dir="${dir// /_}" #replace any spaces with underscores
	done

	/bin/mkdir -p "$dir"
	cd "$dir"
	path=$(pwd)

	echo "Initializing secure jail setup..."

	#set up jail environment directories
	/bin/mkdir -p "$path"
	/bin/mkdir -p "$path/{dev,etc,lib,usr,bin,root,home,var,tmp}"
	/bin/mkdir -p "$path/usr/bin"

	shells=""
	user="none"
	while true; do
		read -p "Enter users to be placed in jail (leave blank if no more users): " user
		if [ "$user" = "" ]; then
			break;
		fi
		shell=$(/bin/grep -e "^$user:" /etc/passwd | /usr/bin/awk -F ":" '{print $7}') #gets full path to shell for current user
		shells="$shells $shell" #adds to shells var
		shell=$(echo "$shell" | /usr/bin/awk -F "/" '{print $NF}') #gets basename of shell

		#copy files for their home dir
		/bin/mkdir -p "${path}/home/$user"
		test -e "/home/$user/.${shell}rc" && /bin/cp "/home/$user/.${shell}rc" "${path}/home/$user"
		test -e "/home/$user/.${shell}_profile" && /bin/cp "/home/$user/.${shell}_profile" "${path}/home/$user"

		if [ -e "/home/$user/.${shell}_profile" ]; then #if there's a shell profile copy it
			/bin/cp "/home/$user/.${shell}_profile" "${path}/home/$user"
		elif [ -e "/home/$user/.profile" ]; then #see if there's a regular profile file
			/bin/cp "/home/$user/.profile" "${path}/home/$user"
		fi
		
		test -e "/home/$user/.${editor}rc" && /bin/cp "/home/$user/.${editor}rc" "${path}/home/$user"
		/bin/chmod -R 750 "${path}/home/$user"
		/bin/chown -R -f "${user}:${user}" "${path}/home/$user"
	done

	echo "Creating jail environment..."
	/bin/chown -f root.root "$path"
	/bin/chmod -f 777 "${path}/tmp"
	/bin/mknod -m 666 "$path/dev/null" c 1 3

	#copy over bare minimum files
	/bin/cp /etc/ld.so.cache "${path}/etc"
	/bin/cp /etc/ld.so.conf "${path}/etc"
	/bin/cp /etc/nsswitch.conf "${path}/etc"
	/bin/cp /etc/hosts "${path}/etc"

	#copy bare minimum executables
	executables="/bin/sh /bin/bash $nologin /bin/ls /bin/cat /bin/cp /bin/mv /bin/rm /bin/mkdir /bin/rmdir /bin/dir /bin/pwd"
	for executable in $executables; do
		/bin/cp "$executable" "${path}/bin"
	done

	/bin/cp "/usr/bin/$editor" "${path}/usr/bin" #copy system editor

	for myShell in $shells; do #if they have non bash shell, link bash to the name of their shell
		if [ ! $(echo "$myShell" | grep -q nologin) ]; then
			if [ "$myShell" != "/bin/bash" -a "$myShell" != "/bin/sh" ]; then
				/bin/ln "${path}/bin/bash" "${path}/${$myShell}" #<- should this really be ${$myShell}?
			fi
		fi
	done

	executables="$executables /usr/bin/$editor"

	#copy appropriate libraries
	for exec in $executables; do
		copy_libraries $exec
	done 2> "$error_file"

	if [ -s "$error_file" ]; then
		echo "Some libraries may not have copied properly"
	fi

	/bin/rm -f "$error_file" #remove error file
fi

if [ "$#" -eq 0 ]; then
	echo "Initializing manual setup"
	suggestJail #get random jail
	read -p "Enter path of jail directory [$sugJail]: " dir
	if [ "$dir" = "" ]; then
		dir="$sugJail"
	fi
	
	while [ -d "$dir" ]; do
		dir="${dir// /_}" #replace any spaces with underscores
		suggestJail #get random jail
		echo "That directory already exists. Please enter another location." >&2
		read -p "Enter path of jail directory [$sugJail]: " dir
		if [ "$dir" = "" ]; then
			dir="$sugJail"
		fi
	done

	/bin/mkdir -p "$dir"
	cd "$dir"
	path="$dir"

	#set up jail environment directories
	/bin/mkdir -p "$path"
	/bin/mkdir -p "$path/{dev,etc,lib,usr,bin,root,home,var,tmp}"
	/bin/mkdir -p "$path/usr/bin"

	user="none"
	while true; do
		read -p "Enter users to be placed in jail (leave blank if no more users): " user
		if [ "$user" = "" ]; then
			break;
		fi
		shell=$(/bin/grep -e "^$user:" /etc/passwd | /usr/bin/awk -F ":" '{print $7}') #gets full path to shell for current user
		shells="$shells $shell" #adds to shells var
		shell=$(echo "$shell" | /usr/bin/awk -F "/" '{print $NF}') #gets basename of shell

		#copy files for their home dir
		/bin/mkdir -p "${path}/home/$user"
		test -e "/home/$user/.${shell}rc" && /bin/cp "/home/$user/.${shell}rc" "${path}/home/$user"
		
		if [ -e "/home/$user/.${shell}_profile" ]; then #if there's a shell profile copy it
			/bin/cp "/home/$user/.${shell}_profile" "${path}/home/$user"
		elif [ -e "/home/$user/.profile" ]; then #see if there's a regular profile file
			/bin/cp "/home/$user/.profile" "${path}/home/$user"
		fi

		test -e "/home/$user/.${editor}rc" && /bin/cp "/home/$user/.${editor}rc" "${path}/home/$user"
		/bin/chmod -R 750 "${path}/home/$user"
		/bin/chown -R -f "${user}:${user}" "${path}/home/$user"
	done
	/bin/chown -f root.root "$path"
	/bin/chmod -f 777 "${path}/tmp"
	/bin/mknod -m 666 "${path}/dev/null" c 1 3

	#copy over bare minimum files
	/bin/cp /etc/ld.so.cache "${path}/etc"
	/bin/cp /etc/ld.so.conf "${path}/etc"
	/bin/cp /etc/nsswitch.conf "${path}/etc"
	/bin/cp /etc/hosts "${path}/etc"

	#ask and copy executables
	executables="sh bash ls cat cp mv rm mkdir rmdir dir pwd"
	read -p "$executables - Would you like to copy these binaries (a/s/n): " choice
	choice=$(echo "$choice" | /usr/bin/tr '[:lower:]' '[:upper:]')

	# echo "Which executables would you like in your jail?"
	# common_bins=`/bin/ls /bin`

	# for i in $common_bins; do
	# 	read -p "$i (Y/N):" choice
	# 	choice=`echo $choice | /usr/bin/tr '[:lower:]' '[:upper:]'`
	# 	if [ "$choice" = "Y" -o "$choice" = "YES" ]; then
	# 		/bin/cp /bin/$i ${path}/bin
	# 		bins="$bins /bin/$i"
	# 	fi
	# done

	read -p "Would you like to choose between a few common binaries in /usr/bin (Y/N): " more_bins
	more_bins=$(echo "$more_bins" | /usr/bin/tr '[:lower:]' '[:upper:]')
	if [ "$more_bins" = "YES" -o "$more_bins" = "Y" ]; then
		other_bins="awk clear cut diff expr head less man nano paste pico split strings strip tail tee test touch tr uniq users uptime vi w wall wc wget whatis who whoami zip zipgrep"

		for i in $other_bins; do
			read -p "$i (Y/N):" choice
			choice=$(echo "$choice" | /usr/bin/tr '[:lower:]' '[:upper:]')
			if [ "$choice" = "Y" -o "$choice" = "YES" ]; then
				/bin/cp "/usr/bin/$i" "${path}/usr/bin"
				bins="$bins /usr/bin/$i"
			fi
		done
	fi

	#copy appropriate libraries
	for exec in $bins; do
		copy_libraries $exec
	done 2> $error_file

	if test -e $error_file; then
		echo "Some libraries may not have copied properly"
	fi

	/bin/rm $error_file #remove error file
fi
