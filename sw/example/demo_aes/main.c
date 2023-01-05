// #################################################################################################
// # << NEORV32 - AES CF Demo Program >>                                                           #
// # ********************************************************************************************* #
// # BSD 3-Clause License                                                                          #
// #                                                                                               #
// # Copyright (c) 2023, Torsten Meissner. All rights reserved.                                    #
// #                                                                                               #
// # Redistribution and use in source and binary forms, with or without modification, are          #
// # permitted provided that the following conditions are met:                                     #
// #                                                                                               #
// # 1. Redistributions of source code must retain the above copyright notice, this list of        #
// #    conditions and the following disclaimer.                                                   #
// #                                                                                               #
// # 2. Redistributions in binary form must reproduce the above copyright notice, this list of     #
// #    conditions and the following disclaimer in the documentation and/or other materials        #
// #    provided with the distribution.                                                            #
// #                                                                                               #
// # 3. Neither the name of the copyright holder nor the names of its contributors may be used to  #
// #    endorse or promote products derived from this software without specific prior written      #
// #    permission.                                                                                #
// #                                                                                               #
// # THIS SOFTWARE IS PROVIDED BY THE COPYRIGHT HOLDERS AND CONTRIBUTORS "AS IS" AND ANY EXPRESS   #
// # OR IMPLIED WARRANTIES, INCLUDING, BUT NOT LIMITED TO, THE IMPLIED WARRANTIES OF               #
// # MERCHANTABILITY AND FITNESS FOR A PARTICULAR PURPOSE ARE DISCLAIMED. IN NO EVENT SHALL THE    #
// # COPYRIGHT HOLDER OR CONTRIBUTORS BE LIABLE FOR ANY DIRECT, INDIRECT, INCIDENTAL, SPECIAL,     #
// # EXEMPLARY, OR CONSEQUENTIAL DAMAGES (INCLUDING, BUT NOT LIMITED TO, PROCUREMENT OF SUBSTITUTE #
// # GOODS OR SERVICES; LOSS OF USE, DATA, OR PROFITS; OR BUSINESS INTERRUPTION) HOWEVER CAUSED    #
// # AND ON ANY THEORY OF LIABILITY, WHETHER IN CONTRACT, STRICT LIABILITY, OR TORT (INCLUDING     #
// # NEGLIGENCE OR OTHERWISE) ARISING IN ANY WAY OUT OF THE USE OF THIS SOFTWARE, EVEN IF ADVISED  #
// # OF THE POSSIBILITY OF SUCH DAMAGE.                                                            #
// # ********************************************************************************************* #
// # The NEORV32 Processor - https://github.com/stnolting/neorv32              (c) Stephan Nolting #
// #################################################################################################


/**********************************************************************//**
 * @file demo_aes/main.c
 * @author Torsten Meissner
 * @brief Minimal blinking AES demo program.
 **************************************************************************/
#include <neorv32.h>


void aes_firq_handler(void);


volatile int aes_irq = 0;


/**********************************************************************//**
 * Main function; shows encryption of some test data
 *
 * @note This program requires the AES CF to be synthesized.
 *
 * @return Will never return.
 **************************************************************************/
int main() {

  //Test data
  uint32_t key[4]   = {0, 1, 2, 3};
  uint32_t nonce[3] = {2, 1, 0};
  uint32_t din[4]   = {5, 5, 5, 5};
  uint32_t dout[4];


  neorv32_rte_setup();
  // install AES interrupt handler
  neorv32_rte_handler_install(AES_RTE_ID, aes_firq_handler);

  // enable interrupt
  neorv32_cpu_irq_enable(AES_FIRQ_ENABLE); // enable GPTMR FIRQ channel
  neorv32_cpu_eint(); // enable global interrupt flag

  neorv32_aes_setup(key, nonce, 1);
  neorv32_aes_write(din);
  neorv32_aes_crypt();

  while (1) {

    if (aes_irq) {
      aes_irq = 0;
      neorv32_aes_read(dout);
      neorv32_aes_crypt();
    }

  }

  return 0;
}


// Interrupt service routine
void aes_firq_handler(void) {

  neorv32_cpu_csr_write(CSR_MIP, ~(1<<AES_FIRQ_PENDING));
  aes_irq = 1;

}