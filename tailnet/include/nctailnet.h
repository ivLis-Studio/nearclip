// Nearclip tailnet bridge — C interface (see tailnet/README.md).
// Every function returning char* returns a JSON status that must be released with NCTailnetFree.
#ifndef NCTAILNET_H
#define NCTAILNET_H

#ifdef __cplusplus
extern "C" {
#endif

char *NCTailnetStart(char *configJSON);
char *NCTailnetStatus(void);
char *NCTailnetLogin(void);
char *NCTailnetLogout(void);
char *NCTailnetStop(void);
char *NCTailnetSetNetwork(char *netInfoJSON);
void NCTailnetNetworkChanged(void);
void NCTailnetFree(char *p);

#ifdef __cplusplus
}
#endif

#endif
