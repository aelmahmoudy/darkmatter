#!/system/bin/sh

APPLIST=(org.whispersystems.whisperpush
at.rundquadrat.android.r2mail2
)

PATH=${PATH}:$(dirname $0)

umask 022

mkdir -p /dev/mapper
mkdir -p /sdcard/Android/data

GMOUNT=mount
GUMOUNT=umount
API=$(getprop ro.build.version.sdk)
if [ "$API" -ge 17 ]; then
  GMOUNT="su --mount-master -c mount"
  GUMOUNT="su --mount-master -c umount"
fi

function map_lookup() { # <volpath>
  local volpath="$1"

  local abspath=$(readlink -f $volpath)
  for i in /dev/mapper/*; do
    local device=$(basename $i)
    if cryptsetup status $device | grep "$abspath" > /dev/null 2>&1; then
      break
    fi
  done
  echo "$device"
}

function volume_create() { # <volpath> <num> <unit>
  local volpath="$1"
  local num="$2"
  local unit="$3"

  case $unit in
    m) count=$num ;;
    M) count=$num ;;
    g) count=$(($num * 1024)) ;;
    G) count=$(($num * 1024)) ;;
    *) echo "unknown unit: $unit!" && exit 200
  esac

  dd if=/dev/urandom of=$volpath bs=$((1024 * 1024)) count=$count
}

function volume_delete() { # <volpath>
  local volpath="$1"

  local volsize=$(ls -l "$volpath"| cut -d' ' -f 12)
  # wipe volume:
  dd if=/dev/zero of="$volpath" bs=$volsize count=1

  rm -f $volpath
}

function setup_app() { # <appname> <mount_dir>
        local appname="$1"
        local tcdir="$2"

        if [ ! -d $tcdir/Android/data ]; then
                mkdir -p "$tcdir/Android/data"
        fi

        if [ ! -d "$tcdir/data" ]; then
                mkdir -p "$tcdir/data"
        fi

        local user=`get_app_user $appname`

        if [ ! -d "$tcdir/Android/data/$appname" ]; then
          mkdir -p "$tcdir/Android/data/$appname"
          chown $user:$user "$tcdir/Android/data/$appname"
  fi

        if [ ! -d "$tcdir/data/$appname" ]; then
          mkdir -p "$tcdir/data/$appname"
          chown $user:$user "$tcdir/data/$appname"
  fi
}

# the device must already be mapped onto a /dev/mapper/$NAME
function cs_mount() { # <tcdevice> <mountpath>
  local tcdevice="$1"
  local path="$2"
  
  if [ ! -d "$path" ]; then
    mount -o remount,rw /
    mkdir -p "$path"
    mount -o remount,ro /
  fi
  
  $GMOUNT -o "noatime,nodev" -t ext4 $tcdevice $path < /dev/null
}

function cs_unmount() { # <device>
  local device="$1"

  local mountpath=$(mount | grep "$device" | head -n 1 | cut -d\  -f2)
  local retries="2"

  # TODO: find mount path !
  # $(seq $retries)
  for i in $(seq $retries); do
    $GUMOUNT $mountpath < /dev/null
  done
}

function cs_map() { # <volpath> <password>
        local volpath="$1"
        local password="$2"

        local name=$(basename $volpath)

        # Check that there is no device named $name already setup:
        cryptsetup status $name > /dev/null 2>&1
        [ $? -eq 4  ] || name=$(mktemp -u XXXXX)

        echo $password | cryptsetup loopaesOpen $volpath $name --key-file=- >&2
        echo $name
}

function cs_unmap() { # <name>
  local name="$1"
  
  cryptsetup close $name
}

function cs_init_device() { # <volpath> <target> <password>
  local volpath="$1"
  local target="$2"
  local password="$3"

  if [ ! -d "$target" ]; then
    mount -o rw,remount /
    mkdir -p $target
    mount -o ro,remount /
  fi

  local name=$(cs_map "$volpath" "$password")
  mkfs.ext2 -O ^has_journal /dev/mapper/$name
  mount -o "noatime,nodev" -t ext4 /dev/mapper/$name "$target"
  mkdir -p "$target/data" 
  mkdir -p "$target/Android/data"
  chmod 0755 "$target/data"
  chmod 0755 "$target/Android/data"
  for appname in ${APPLIST[*]}; do
    setup_app "$appname" "$target"
  done
  umount "$target"
  cs_unmap "$name"
}

function cs_create() { # <volpath> <size> <password>
  local volpath="$1"
  local size="$2"
  local password="$3"

  # dd /dev/zero, volpath, num_mb, "M" (or 'G' for num_gb)
  volume_create "$volpath" "$size" "M"

  local target=$(mktemp -d)

  cs_init_device "$volpath" "$target" "$password"
  rmdir "$target"
}

function get_app_user() {
        echo $(ls -ld "/data/data/$1"| cut -d' ' -f 2)
}

function bind_mount() { # <from> <dest> <user>
  local from="$1"
  local dest="$2"
  local user="$3"

  local m=$(grep "$dest" /proc/mounts| wc -l)
  if [ $m -ne 0 ]; then
                return 1
  fi

  $GMOUNT -o bind,user=$user,relatime,nodev $from $dest < /dev/null
  return $?
}

function app_mount() { # <app_name> <mount_path>
  local appname="$1"
  local tcdir="$2"
  local user=`get_app_user $appname`

  # make sure nothing is open on our target directory. maybe
  killall $appname >/dev/null 2>/dev/null

  if [ ! -d "$tcdir/data/$appname" ]; then
    setup_app "$tcdir" "$appname"
  fi

  if [ -d "/data/data/$appname" ]; then
    bind_mount "$tcdir/data/$appname" "/data/data/$appname" "$user"
  fi
  if [ -d "/sdcard/Android/data/$appname" ]; then
    bind_mount "$tcdir/Android/data/$appname" "/sdcard/Android/data/$appname" "$user"
  fi
}

function app_umount() { # <app_name>
  local appname="$1"
  
  killall $appname >/dev/null 2>/dev/null

  if [ -d "/data/data/$appname" ]; then
    $GUMOUNT "/data/data/$appname" < /dev/null
  fi
  if [ -d "/sdcard/Android/data/$appname" ]; then
    $GUMOUNT "/sdcard/Android/data/$appname" < /dev/null
  fi
}

function app_kill() { # <package>
  local package=$1

  local pkgexist=$(pm list packages $package | wc -l)

  if [ $pkgexist -ne 0 ]; then
    am force-stop "$package"
  fi
}

function cs_open() { # <volpath> <mountpath> <password>
  local volume="$1"
  local path="$2"
  local password="$3"

  local absvolpath=$(readlink -f $volume)
  local name=$(cs_map "$absvolpath" "$password")
  cs_mount "/dev/mapper/$name" "$path"
    
  for app in ${APPLIST[*]}; do
    app_kill "$app"
    app_mount "$app" "$path"
  done
}

function cs_close() { # <volpath>
  local volpath="$1"
  local name=$(map_lookup "$volpath")

  for app in ${APPLIST[*]}; do
    app_kill "$app"
    app_umount "$app" "$path"
  done

  cs_unmount "/dev/mapper/$name"
  cs_unmap "$name"
}

function cs_delete() { # <volpath>
  local volpath="$1"

  volume_delete "$volpath"
}

case $1 in
  "create")
    shift
    cs_create "$@"
    ;;
  "open")
    shift # discard first arg
    cs_open "$@"
    exit 0
    ;;
  "close")
    shift
    cs_close "$@"
    ;;
  "delete")
    shift
    cs_delete "$@"
    ;;
  *)
    echo "$0 <create|open|close|delete> [args]" 
    exit 127
    ;;
esac

