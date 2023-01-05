#ifndef neorv32_aes_h
#define neorv32_aes_h

// ctrl reg bits
#define AES_CTRL_AES_RESET 0
#define AES_CTRL_CTR_START 1
#define AES_CTRL_AES_START 2
#define AES_CTRL_AES_END   3
#define AES_CTRL_IRQ_EN    4

// prototypes
int neorv32_aes_available(void);
void neorv32_aes_setup(const uint32_t *key, const uint32_t *nonce, const uint8_t irq);
void neorv32_aes_crypt(void);
void neorv32_aes_write(const uint32_t *data);
void neorv32_aes_read(uint32_t *data);

#endif // neorv32_aes_h
