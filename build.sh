for mariadb_ver in "10.1" "10.2" "10.3"; do
    
    for docker_arch in "amd64" "arm32v6"; do
        
        # For arm we have only mariadb 10.1, at least for now
        if [ ${docker_arch} == "arm32v6" ] && [ ${mariadb_ver} != "10.1" ]; then
            break
        fi
        
        
        cp Dockerfile.template Dockerfile-${mariadb_ver}.${docker_arch}
        
        # Architecture-specific base image
        case ${docker_arch} in
            amd64   )  sed -i "s|__BASEIMAGE_ARCH__|mariadb:${mariadb_ver}|g" Dockerfile-${mariadb_ver}.${docker_arch} ;;
            arm32v6 )  sed -i "s|__BASEIMAGE_ARCH__|linuxserver/mariadb:arm32v7-110.3.16mariabionic-ls21|g" Dockerfile-${mariadb_ver}.${docker_arch} ;;
        esac
        
        # Architecture-specific binaries
        sed -i "s|__DOCKER_ARCH__|${docker_arch}|g" Dockerfile-${mariadb_ver}.${docker_arch}
        
        # SST method based on mariadb version
        if [ ${mariadb_ver} == "10.1" ]; then
            sed -i "s|__SST_METHOD__|xtrabackup-v2|g" Dockerfile-${mariadb_ver}.${docker_arch}
        else
            sed -i "s|__SST_METHOD__|mariabackup|g" Dockerfile-${mariadb_ver}.${docker_arch}
        fi
        
    done
    
done