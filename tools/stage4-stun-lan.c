/* Workstation-only STUN client. Never built or installed on the router. */
#include <sys/socket.h>
#include <net/if.h>
#include <netinet/in.h>
#include <arpa/inet.h>
#include <errno.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>
#include <unistd.h>

static unsigned word(const unsigned char *p) { return (p[0] << 8) | p[1]; }
int main(int argc, char **argv) {
    if (argc != 4) { fprintf(stderr,"Usage: stun-lan INTERFACE IPV4 PORT\n"); return 2; }
    char *end = NULL;
    long port = strtol(argv[3], &end, 10);
    unsigned index = if_nametoindex(argv[1]);
    struct sockaddr_in peer = { .sin_family = AF_INET, .sin_port = htons((unsigned short)port) };
    if (!index || *end || port < 1 || port > 65535 || inet_pton(AF_INET,argv[2],&peer.sin_addr)!=1) return 2;
    int s = socket(AF_INET,SOCK_DGRAM,0);
    if (s < 0) return 1;
#ifdef __APPLE__
    if (setsockopt(s,IPPROTO_IP,IP_BOUND_IF,&index,sizeof(index))) { perror("IP_BOUND_IF"); return 1; }
#else
    if (setsockopt(s,SOL_SOCKET,SO_BINDTODEVICE,argv[1],strlen(argv[1])+1)) { perror("SO_BINDTODEVICE"); return 1; }
#endif
    struct timeval timeout = { .tv_sec=3, .tv_usec=0 };
    if (setsockopt(s,SOL_SOCKET,SO_RCVTIMEO,&timeout,sizeof(timeout)) || connect(s,(struct sockaddr *)&peer,sizeof(peer))) return 1;
    unsigned char request[20] = {0,1,0,0,0x21,0x12,0xa4,0x42}, reply[2048];
    arc4random_buf(request+8,12);
    struct timespec start, finish;
    clock_gettime(CLOCK_MONOTONIC,&start);
    const char *limit=getenv("STUN_ATTEMPTS");
    int attempts=limit ? atoi(limit) : 3;
    if (attempts<1 || attempts>3) return 2;
    for (int attempt=0;attempt<attempts;attempt++) {
        if (send(s,request,sizeof(request),0)!=(ssize_t)sizeof(request)) break;
        ssize_t n=recv(s,reply,sizeof(reply),0);
        if (n<20) continue;
        if (word(reply)!=0x0101 || memcmp(reply+4,request+4,16) || word(reply+2)+20>(unsigned)n) continue;
        for (unsigned pos=20;pos+4<=word(reply+2)+20;) {
            unsigned type=word(reply+pos), len=word(reply+pos+2);
            if (pos+4+len>(unsigned)n) break;
            if (type==0x0020 && len>=8 && reply[pos+5]==1) {
                unsigned char ip[4];
                for (int i=0;i<4;i++) ip[i]=reply[pos+8+i]^request[4+i];
                char address[INET_ADDRSTRLEN];
                if (!inet_ntop(AF_INET,ip,address,sizeof(address))) return 1;
                clock_gettime(CLOCK_MONOTONIC,&finish);
                double ms=(finish.tv_sec-start.tv_sec)*1000.0+(finish.tv_nsec-start.tv_nsec)/1000000.0;
                printf("{\"status\":\"up\",\"external_ip\":\"%s\",\"mapped_port\":%u,\"latency_ms\":%.2f}\n",address,word(reply+pos+6)^0x2112,ms);
                close(s); return 0;
            }
            pos+=4+((len+3)&~3U);
        }
    }
    close(s);
    fprintf(stderr,"STUN request failed or timed out on the explicitly bound LAN interface\n");
    return 1;
}
