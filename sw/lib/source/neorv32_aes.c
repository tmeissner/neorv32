#include "neorv32.h"
#include "neorv32_aes.h"


/**********************************************************************//**
* Check if AES custom functions unit was synthesized.
*
* @return 0 if AES was not synthesized, 1 if AES is available.
**************************************************************************/
int neorv32_aes_available(void) {

  if (NEORV32_SYSINFO.SOC & (1 << SYSINFO_SOC_IO_AES)) {
    return 1;
  }
  else {
    return 0;
  }
}


void neorv32_aes_setup(const uint32_t *key, const uint32_t *nonce, const uint8_t irq) {

  // Reset
  NEORV32_AES.CTRL = 0;

  // Set key
  for (int i = 0; i <= 3; i++) {
    NEORV32_AES.KEY = key[i];
  }

  // Set nonce
  for (int i = 0; i <= 2; i++) {
    NEORV32_AES.NONCE = nonce[i];
  }

  // Set counter start (1st round)
  uint32_t ctr_start = 1 << AES_CTRL_CTR_START;
  uint32_t irq_en    = irq << AES_CTRL_IRQ_EN;
  
  NEORV32_AES.CTRL = ctr_start | irq_en;
}


void neorv32_aes_crypt(void) {

  uint32_t ctrl_reg = NEORV32_AES.CTRL;

  // Set aes start
  uint32_t aes_start = 1 << AES_CTRL_AES_START;
  
  NEORV32_AES.CTRL = ctrl_reg | aes_start;
}


void neorv32_aes_write(const uint32_t *data) {

  for (int i = 0; i <= 3; i++) {
    NEORV32_AES.WDATA = data[i];
  }
}


void neorv32_aes_read(uint32_t *data) {

  uint32_t ctrl_reg;

  // Wait until aes calc ended
  do {
    ctrl_reg = NEORV32_AES.CTRL;
  } while (!(ctrl_reg & (1 << AES_CTRL_AES_END)));

  // Read aes dout reg
  for (int i = 0; i <= 3; i++) {
    *data++ = NEORV32_AES.RDATA;
  }
}
