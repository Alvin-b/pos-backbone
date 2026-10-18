export type Json =
  | string
  | number
  | boolean
  | null
  | { [key: string]: Json | undefined }
  | Json[]

export type Database = {
  // Allows to automatically instantiate createClient with right options
  // instead of createClient<Database, { PostgrestVersion: 'XX' }>(URL, KEY)
  __InternalSupabase: {
    PostgrestVersion: "14.18"
  }
  public: {
    Tables: {
      access_challenges: {
        Row: {
          approved_at: string | null
          approved_by: string | null
          consumed_at: string | null
          consumed_by: string | null
          created_at: string
          expires_at: string
          id: string
          processing_at: string | null
          role: Database["public"]["Enums"]["shop_role"] | null
          shop_id: string | null
          status: string
          token_hash: string
        }
        Insert: {
          approved_at?: string | null
          approved_by?: string | null
          consumed_at?: string | null
          consumed_by?: string | null
          created_at?: string
          expires_at?: string
          id?: string
          processing_at?: string | null
          role?: Database["public"]["Enums"]["shop_role"] | null
          shop_id?: string | null
          status?: string
          token_hash: string
        }
        Update: {
          approved_at?: string | null
          approved_by?: string | null
          consumed_at?: string | null
          consumed_by?: string | null
          created_at?: string
          expires_at?: string
          id?: string
          processing_at?: string | null
          role?: Database["public"]["Enums"]["shop_role"] | null
          shop_id?: string | null
          status?: string
          token_hash?: string
        }
        Relationships: [
          {
            foreignKeyName: "access_challenges_shop_id_fkey"
            columns: ["shop_id"]
            isOneToOne: false
            referencedRelation: "shops"
            referencedColumns: ["id"]
          },
        ]
      }
      access_passes: {
        Row: {
          created_at: string
          created_by: string
          expires_at: string
          id: string
          pass_hash: string
          redeemed_at: string | null
          redeemed_by: string | null
          revoked_at: string | null
          role: Database["public"]["Enums"]["shop_role"]
          shop_id: string
        }
        Insert: {
          created_at?: string
          created_by: string
          expires_at?: string
          id?: string
          pass_hash: string
          redeemed_at?: string | null
          redeemed_by?: string | null
          revoked_at?: string | null
          role: Database["public"]["Enums"]["shop_role"]
          shop_id: string
        }
        Update: {
          created_at?: string
          created_by?: string
          expires_at?: string
          id?: string
          pass_hash?: string
          redeemed_at?: string | null
          redeemed_by?: string | null
          revoked_at?: string | null
          role?: Database["public"]["Enums"]["shop_role"]
          shop_id?: string
        }
        Relationships: [
          {
            foreignKeyName: "access_passes_shop_id_fkey"
            columns: ["shop_id"]
            isOneToOne: false
            referencedRelation: "shops"
            referencedColumns: ["id"]
          },
        ]
      }
      audit_events: {
        Row: {
          action: string
          actor_user_id: string | null
          created_at: string
          entity_id: string | null
          entity_type: string
          id: string
          metadata: Json
          shop_id: string | null
        }
        Insert: {
          action: string
          actor_user_id?: string | null
          created_at?: string
          entity_id?: string | null
          entity_type: string
          id?: string
          metadata?: Json
          shop_id?: string | null
        }
        Update: {
          action?: string
          actor_user_id?: string | null
          created_at?: string
          entity_id?: string | null
          entity_type?: string
          id?: string
          metadata?: Json
          shop_id?: string | null
        }
        Relationships: [
          {
            foreignKeyName: "audit_events_shop_id_fkey"
            columns: ["shop_id"]
            isOneToOne: false
            referencedRelation: "shops"
            referencedColumns: ["id"]
          },
        ]
      }
      catalog_items: {
        Row: {
          barcode: string | null
          body_color: string | null
          brand: string | null
          category: string | null
          code: string
          created_at: string
          id: string
          image_url: string | null
          label_color: string | null
          label_text_color: string | null
          name: string
          product_type: Database["public"]["Enums"]["product_type"]
          size: string | null
          suggested_price: number
        }
        Insert: {
          barcode?: string | null
          body_color?: string | null
          brand?: string | null
          category?: string | null
          code: string
          created_at?: string
          id?: string
          image_url?: string | null
          label_color?: string | null
          label_text_color?: string | null
          name: string
          product_type?: Database["public"]["Enums"]["product_type"]
          size?: string | null
          suggested_price?: number
        }
        Update: {
          barcode?: string | null
          body_color?: string | null
          brand?: string | null
          category?: string | null
          code?: string
          created_at?: string
          id?: string
          image_url?: string | null
          label_color?: string | null
          label_text_color?: string | null
          name?: string
          product_type?: Database["public"]["Enums"]["product_type"]
          size?: string | null
          suggested_price?: number
        }
        Relationships: []
      }
      employee_working_hours: {
        Row: {
          enabled: boolean
          end_time: string
          shop_id: string
          start_time: string
          updated_at: string
          updated_by: string | null
          user_id: string
          weekday: number
        }
        Insert: {
          enabled?: boolean
          end_time: string
          shop_id: string
          start_time: string
          updated_at?: string
          updated_by?: string | null
          user_id: string
          weekday: number
        }
        Update: {
          enabled?: boolean
          end_time?: string
          shop_id?: string
          start_time?: string
          updated_at?: string
          updated_by?: string | null
          user_id?: string
          weekday?: number
        }
        Relationships: [
          {
            foreignKeyName: "employee_working_hours_shop_id_fkey"
            columns: ["shop_id"]
            isOneToOne: false
            referencedRelation: "shops"
            referencedColumns: ["id"]
          },
        ]
      }
      platform_admin_tokens: {
        Row: {
          auth_user_id: string
          expires_at: string
          issued_at: string
          issued_by: string | null
          last_redeemed_at: string | null
          singleton: boolean
          token_hash: string
        }
        Insert: {
          auth_user_id: string
          expires_at: string
          issued_at?: string
          issued_by?: string | null
          last_redeemed_at?: string | null
          singleton?: boolean
          token_hash: string
        }
        Update: {
          auth_user_id?: string
          expires_at?: string
          issued_at?: string
          issued_by?: string | null
          last_redeemed_at?: string | null
          singleton?: boolean
          token_hash?: string
        }
        Relationships: []
      }
      platform_admins: {
        Row: {
          created_at: string
          created_by: string | null
          user_id: string
        }
        Insert: {
          created_at?: string
          created_by?: string | null
          user_id: string
        }
        Update: {
          created_at?: string
          created_by?: string | null
          user_id?: string
        }
        Relationships: []
      }
      products: {
        Row: {
          archived: boolean
          average_cost: number
          barcode: string | null
          body_color: string | null
          brand: string | null
          catalog_item_id: string | null
          category: string | null
          code: string
          created_at: string
          id: string
          label_color: string | null
          label_text_color: string | null
          name: string
          photo_path: string | null
          photo_url: string | null
          price: number
          product_type: Database["public"]["Enums"]["product_type"]
          shop_id: string
          size: string | null
          stock: number
          updated_at: string
        }
        Insert: {
          archived?: boolean
          average_cost?: number
          barcode?: string | null
          body_color?: string | null
          brand?: string | null
          catalog_item_id?: string | null
          category?: string | null
          code: string
          created_at?: string
          id?: string
          label_color?: string | null
          label_text_color?: string | null
          name: string
          photo_path?: string | null
          photo_url?: string | null
          price: number
          product_type?: Database["public"]["Enums"]["product_type"]
          shop_id: string
          size?: string | null
          stock?: number
          updated_at?: string
        }
        Update: {
          archived?: boolean
          average_cost?: number
          barcode?: string | null
          body_color?: string | null
          brand?: string | null
          catalog_item_id?: string | null
          category?: string | null
          code?: string
          created_at?: string
          id?: string
          label_color?: string | null
          label_text_color?: string | null
          name?: string
          photo_path?: string | null
          photo_url?: string | null
          price?: number
          product_type?: Database["public"]["Enums"]["product_type"]
          shop_id?: string
          size?: string | null
          stock?: number
          updated_at?: string
        }
        Relationships: [
          {
            foreignKeyName: "products_catalog_item_id_fkey"
            columns: ["catalog_item_id"]
            isOneToOne: false
            referencedRelation: "catalog_items"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "products_shop_id_fkey"
            columns: ["shop_id"]
            isOneToOne: false
            referencedRelation: "shops"
            referencedColumns: ["id"]
          },
        ]
      }
      sale_batch_allocations: {
        Row: {
          batch_id: string
          qty: number
          sale_id: string
          unit_cost: number
        }
        Insert: {
          batch_id: string
          qty: number
          sale_id: string
          unit_cost: number
        }
        Update: {
          batch_id?: string
          qty?: number
          sale_id?: string
          unit_cost?: number
        }
        Relationships: [
          {
            foreignKeyName: "sale_batch_allocations_batch_id_fkey"
            columns: ["batch_id"]
            isOneToOne: false
            referencedRelation: "stock_batches"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "sale_batch_allocations_sale_id_fkey"
            columns: ["sale_id"]
            isOneToOne: false
            referencedRelation: "sales"
            referencedColumns: ["id"]
          },
        ]
      }
      sales: {
        Row: {
          created_at: string
          id: string
          product_id: string
          product_name: string
          profit_total: number
          qty: number
          shop_id: string
          sold_by: string
          stock_qty: number
          total: number
          undone_at: string | null
          undone_by: string | null
          unit_cost_total: number
          unit_name: string
          unit_price: number
        }
        Insert: {
          created_at?: string
          id?: string
          product_id: string
          product_name: string
          profit_total?: number
          qty: number
          shop_id: string
          sold_by: string
          stock_qty?: number
          total: number
          undone_at?: string | null
          undone_by?: string | null
          unit_cost_total?: number
          unit_name?: string
          unit_price: number
        }
        Update: {
          created_at?: string
          id?: string
          product_id?: string
          product_name?: string
          profit_total?: number
          qty?: number
          shop_id?: string
          sold_by?: string
          stock_qty?: number
          total?: number
          undone_at?: string | null
          undone_by?: string | null
          unit_cost_total?: number
          unit_name?: string
          unit_price?: number
        }
        Relationships: [
          {
            foreignKeyName: "sales_product_id_fkey"
            columns: ["product_id"]
            isOneToOne: false
            referencedRelation: "products"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "sales_shop_id_fkey"
            columns: ["shop_id"]
            isOneToOne: false
            referencedRelation: "shops"
            referencedColumns: ["id"]
          },
        ]
      }
      service_counters: {
        Row: {
          active: boolean
          created_at: string
          created_by: string | null
          id: string
          name: string
          shop_id: string
        }
        Insert: {
          active?: boolean
          created_at?: string
          created_by?: string | null
          id?: string
          name: string
          shop_id: string
        }
        Update: {
          active?: boolean
          created_at?: string
          created_by?: string | null
          id?: string
          name?: string
          shop_id?: string
        }
        Relationships: [
          {
            foreignKeyName: "service_counters_shop_id_fkey"
            columns: ["shop_id"]
            isOneToOne: false
            referencedRelation: "shops"
            referencedColumns: ["id"]
          },
        ]
      }
      shop_members: {
        Row: {
          created_at: string
          employment_status: string
          role: Database["public"]["Enums"]["shop_role"]
          shop_id: string
          status_changed_at: string | null
          status_changed_by: string | null
          status_reason: string | null
          user_id: string
        }
        Insert: {
          created_at?: string
          employment_status?: string
          role?: Database["public"]["Enums"]["shop_role"]
          shop_id: string
          status_changed_at?: string | null
          status_changed_by?: string | null
          status_reason?: string | null
          user_id: string
        }
        Update: {
          created_at?: string
          employment_status?: string
          role?: Database["public"]["Enums"]["shop_role"]
          shop_id?: string
          status_changed_at?: string | null
          status_changed_by?: string | null
          status_reason?: string | null
          user_id?: string
        }
        Relationships: [
          {
            foreignKeyName: "shop_members_shop_id_fkey"
            columns: ["shop_id"]
            isOneToOne: false
            referencedRelation: "shops"
            referencedColumns: ["id"]
          },
        ]
      }
      shops: {
        Row: {
          business_size: string
          business_type: string
          closed_at: string | null
          closed_by: string | null
          closure_reason: string | null
          counter_inventory_mode: string
          created_at: string
          created_by: string
          currency: string
          feature_flags: Json
          id: string
          low_stock_threshold: number
          name: string
          owner_email: string | null
          status: string
          suspended_at: string | null
          suspended_by: string | null
          suspension_reason: string | null
          timezone: string
        }
        Insert: {
          business_size?: string
          business_type?: string
          closed_at?: string | null
          closed_by?: string | null
          closure_reason?: string | null
          counter_inventory_mode?: string
          created_at?: string
          created_by: string
          currency?: string
          feature_flags?: Json
          id?: string
          low_stock_threshold?: number
          name: string
          owner_email?: string | null
          status?: string
          suspended_at?: string | null
          suspended_by?: string | null
          suspension_reason?: string | null
          timezone?: string
        }
        Update: {
          business_size?: string
          business_type?: string
          closed_at?: string | null
          closed_by?: string | null
          closure_reason?: string | null
          counter_inventory_mode?: string
          created_at?: string
          created_by?: string
          currency?: string
          feature_flags?: Json
          id?: string
          low_stock_threshold?: number
          name?: string
          owner_email?: string | null
          status?: string
          suspended_at?: string | null
          suspended_by?: string | null
          suspension_reason?: string | null
          timezone?: string
        }
        Relationships: []
      }
      stock_batches: {
        Row: {
          id: string
          notes: string | null
          product_id: string
          receipt_id: string | null
          received_at: string
          received_by: string
          received_qty: number
          reference: string | null
          remaining_qty: number
          shop_id: string
          unit_cost: number
        }
        Insert: {
          id?: string
          notes?: string | null
          product_id: string
          receipt_id?: string | null
          received_at?: string
          received_by: string
          received_qty: number
          reference?: string | null
          remaining_qty: number
          shop_id: string
          unit_cost?: number
        }
        Update: {
          id?: string
          notes?: string | null
          product_id?: string
          receipt_id?: string | null
          received_at?: string
          received_by?: string
          received_qty?: number
          reference?: string | null
          remaining_qty?: number
          shop_id?: string
          unit_cost?: number
        }
        Relationships: [
          {
            foreignKeyName: "stock_batches_product_id_fkey"
            columns: ["product_id"]
            isOneToOne: false
            referencedRelation: "products"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "stock_batches_receipt_id_fkey"
            columns: ["receipt_id"]
            isOneToOne: false
            referencedRelation: "stock_receipts"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "stock_batches_shop_id_fkey"
            columns: ["shop_id"]
            isOneToOne: false
            referencedRelation: "shops"
            referencedColumns: ["id"]
          },
        ]
      }
      stock_receipts: {
        Row: {
          created_at: string
          id: string
          is_new_product: boolean
          notes: string | null
          product_id: string
          qty: number
          received_by: string
          reference: string | null
          shop_id: string
          supplier: string | null
          unit_cost: number
        }
        Insert: {
          created_at?: string
          id?: string
          is_new_product?: boolean
          notes?: string | null
          product_id: string
          qty: number
          received_by: string
          reference?: string | null
          shop_id: string
          supplier?: string | null
          unit_cost?: number
        }
        Update: {
          created_at?: string
          id?: string
          is_new_product?: boolean
          notes?: string | null
          product_id?: string
          qty?: number
          received_by?: string
          reference?: string | null
          shop_id?: string
          supplier?: string | null
          unit_cost?: number
        }
        Relationships: [
          {
            foreignKeyName: "stock_receipts_product_id_fkey"
            columns: ["product_id"]
            isOneToOne: false
            referencedRelation: "products"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "stock_receipts_shop_id_fkey"
            columns: ["shop_id"]
            isOneToOne: false
            referencedRelation: "shops"
            referencedColumns: ["id"]
          },
        ]
      }
    }
    Views: {
      [_ in never]: never
    }
    Functions: {
      add_from_catalog: {
        Args: {
          _catalog: string
          _price?: number
          _qty?: number
          _shop: string
        }
        Returns: {
          archived: boolean
          average_cost: number
          barcode: string | null
          body_color: string | null
          brand: string | null
          catalog_item_id: string | null
          category: string | null
          code: string
          created_at: string
          id: string
          label_color: string | null
          label_text_color: string | null
          name: string
          photo_path: string | null
          photo_url: string | null
          price: number
          product_type: Database["public"]["Enums"]["product_type"]
          shop_id: string
          size: string | null
          stock: number
          updated_at: string
        }
        SetofOptions: {
          from: "*"
          to: "products"
          isOneToOne: true
          isSetofReturn: false
        }
      }
      add_from_catalog_with_cost: {
        Args: {
          _catalog: string
          _price?: number
          _qty?: number
          _shop: string
          _unit_cost?: number
        }
        Returns: {
          archived: boolean
          average_cost: number
          barcode: string | null
          body_color: string | null
          brand: string | null
          catalog_item_id: string | null
          category: string | null
          code: string
          created_at: string
          id: string
          label_color: string | null
          label_text_color: string | null
          name: string
          photo_path: string | null
          photo_url: string | null
          price: number
          product_type: Database["public"]["Enums"]["product_type"]
          shop_id: string
          size: string | null
          stock: number
          updated_at: string
        }
        SetofOptions: {
          from: "*"
          to: "products"
          isOneToOne: true
          isSetofReturn: false
        }
      }
      add_member_by_email: {
        Args: {
          _email: string
          _role?: Database["public"]["Enums"]["shop_role"]
          _shop: string
        }
        Returns: undefined
      }
      adjust_stock: {
        Args: { _new_stock: number; _product: string; _reason?: string }
        Returns: {
          archived: boolean
          average_cost: number
          barcode: string | null
          body_color: string | null
          brand: string | null
          catalog_item_id: string | null
          category: string | null
          code: string
          created_at: string
          id: string
          label_color: string | null
          label_text_color: string | null
          name: string
          photo_path: string | null
          photo_url: string | null
          price: number
          product_type: Database["public"]["Enums"]["product_type"]
          shop_id: string
          size: string | null
          stock: number
          updated_at: string
        }
        SetofOptions: {
          from: "*"
          to: "products"
          isOneToOne: true
          isSetofReturn: false
        }
      }
      admin_create_business: {
        Args: {
          _business_size?: string
          _business_type?: string
          _name: string
          _owner_email?: string
        }
        Returns: {
          business_size: string
          business_type: string
          closed_at: string | null
          closed_by: string | null
          closure_reason: string | null
          counter_inventory_mode: string
          created_at: string
          created_by: string
          currency: string
          feature_flags: Json
          id: string
          low_stock_threshold: number
          name: string
          owner_email: string | null
          status: string
          suspended_at: string | null
          suspended_by: string | null
          suspension_reason: string | null
          timezone: string
        }
        SetofOptions: {
          from: "*"
          to: "shops"
          isOneToOne: true
          isSetofReturn: false
        }
      }
      admin_create_business_profile: {
        Args: {
          _business_size?: string
          _business_type?: string
          _counter_count?: number
          _counter_inventory_mode?: string
          _name: string
          _owner_email?: string
        }
        Returns: {
          business_size: string
          business_type: string
          closed_at: string | null
          closed_by: string | null
          closure_reason: string | null
          counter_inventory_mode: string
          created_at: string
          created_by: string
          currency: string
          feature_flags: Json
          id: string
          low_stock_threshold: number
          name: string
          owner_email: string | null
          status: string
          suspended_at: string | null
          suspended_by: string | null
          suspension_reason: string | null
          timezone: string
        }
        SetofOptions: {
          from: "*"
          to: "shops"
          isOneToOne: true
          isSetofReturn: false
        }
      }
      admin_list_businesses: {
        Args: never
        Returns: {
          business_size: string
          business_type: string
          closed_at: string
          created_at: string
          feature_flags: Json
          lifecycle_reason: string
          member_count: number
          owner_email: string
          product_count: number
          shop_id: string
          shop_name: string
          status: string
          stock_units: number
          suspended_at: string
        }[]
      }
      admin_list_shop_members: {
        Args: { _shop: string }
        Returns: {
          email: string
          employment_status: string
          member_user_id: string
          role: string
          schedule: Json
          status_reason: string
        }[]
      }
      admin_set_business_status: {
        Args: { _reason?: string; _shop: string; _status: string }
        Returns: {
          business_size: string
          business_type: string
          closed_at: string | null
          closed_by: string | null
          closure_reason: string | null
          counter_inventory_mode: string
          created_at: string
          created_by: string
          currency: string
          feature_flags: Json
          id: string
          low_stock_threshold: number
          name: string
          owner_email: string | null
          status: string
          suspended_at: string | null
          suspended_by: string | null
          suspension_reason: string | null
          timezone: string
        }
        SetofOptions: {
          from: "*"
          to: "shops"
          isOneToOne: true
          isSetofReturn: false
        }
      }
      can_sell_for_shop: { Args: { _shop: string }; Returns: boolean }
      clear_employee_schedule: {
        Args: { _shop: string; _user: string }
        Returns: undefined
      }
      create_shop: {
        Args: { _name: string }
        Returns: {
          business_size: string
          business_type: string
          closed_at: string | null
          closed_by: string | null
          closure_reason: string | null
          counter_inventory_mode: string
          created_at: string
          created_by: string
          currency: string
          feature_flags: Json
          id: string
          low_stock_threshold: number
          name: string
          owner_email: string | null
          status: string
          suspended_at: string | null
          suspended_by: string | null
          suspension_reason: string | null
          timezone: string
        }
        SetofOptions: {
          from: "*"
          to: "shops"
          isOneToOne: true
          isSetofReturn: false
        }
      }
      daily_summary: { Args: { _day?: string; _shop: string }; Returns: Json }
      find_product: {
        Args: { _query: string; _shop: string }
        Returns: {
          archived: boolean
          average_cost: number
          barcode: string | null
          body_color: string | null
          brand: string | null
          catalog_item_id: string | null
          category: string | null
          code: string
          created_at: string
          id: string
          label_color: string | null
          label_text_color: string | null
          name: string
          photo_path: string | null
          photo_url: string | null
          price: number
          product_type: Database["public"]["Enums"]["product_type"]
          shop_id: string
          size: string | null
          stock: number
          updated_at: string
        }[]
        SetofOptions: {
          from: "*"
          to: "products"
          isOneToOne: false
          isSetofReturn: true
        }
      }
      has_shop_role: {
        Args: {
          _roles: Database["public"]["Enums"]["shop_role"][]
          _shop: string
        }
        Returns: boolean
      }
      is_inventory_operator: { Args: { _shop: string }; Returns: boolean }
      is_platform_admin: { Args: never; Returns: boolean }
      is_shop_active: { Args: { _shop: string }; Returns: boolean }
      is_shop_manager: { Args: { _shop: string }; Returns: boolean }
      is_shop_member: { Args: { _shop: string }; Returns: boolean }
      is_shop_owner: { Args: { _shop: string }; Returns: boolean }
      my_account: { Args: never; Returns: Json }
      receive_stock: {
        Args: { _product: string; _qty: number }
        Returns: {
          archived: boolean
          average_cost: number
          barcode: string | null
          body_color: string | null
          brand: string | null
          catalog_item_id: string | null
          category: string | null
          code: string
          created_at: string
          id: string
          label_color: string | null
          label_text_color: string | null
          name: string
          photo_path: string | null
          photo_url: string | null
          price: number
          product_type: Database["public"]["Enums"]["product_type"]
          shop_id: string
          size: string | null
          stock: number
          updated_at: string
        }
        SetofOptions: {
          from: "*"
          to: "products"
          isOneToOne: true
          isSetofReturn: false
        }
      }
      receive_stock_with_cost: {
        Args: {
          _notes?: string
          _product: string
          _qty: number
          _reference?: string
          _supplier?: string
          _unit_cost?: number
        }
        Returns: {
          archived: boolean
          average_cost: number
          barcode: string | null
          body_color: string | null
          brand: string | null
          catalog_item_id: string | null
          category: string | null
          code: string
          created_at: string
          id: string
          label_color: string | null
          label_text_color: string | null
          name: string
          photo_path: string | null
          photo_url: string | null
          price: number
          product_type: Database["public"]["Enums"]["product_type"]
          shop_id: string
          size: string | null
          stock: number
          updated_at: string
        }
        SetofOptions: {
          from: "*"
          to: "products"
          isOneToOne: true
          isSetofReturn: false
        }
      }
      record_sale: {
        Args: { _product: string; _qty?: number }
        Returns: {
          created_at: string
          id: string
          product_id: string
          product_name: string
          profit_total: number
          qty: number
          shop_id: string
          sold_by: string
          stock_qty: number
          total: number
          undone_at: string | null
          undone_by: string | null
          unit_cost_total: number
          unit_name: string
          unit_price: number
        }
        SetofOptions: {
          from: "*"
          to: "sales"
          isOneToOne: true
          isSetofReturn: false
        }
      }
      record_sale_unit: {
        Args: {
          _product: string
          _qty?: number
          _unit_name?: string
          _unit_price?: number
        }
        Returns: {
          created_at: string
          id: string
          product_id: string
          product_name: string
          profit_total: number
          qty: number
          shop_id: string
          sold_by: string
          stock_qty: number
          total: number
          undone_at: string | null
          undone_by: string | null
          unit_cost_total: number
          unit_name: string
          unit_price: number
        }
        SetofOptions: {
          from: "*"
          to: "sales"
          isOneToOne: true
          isSetofReturn: false
        }
      }
      redeem_access_pass_atomic: {
        Args: { _pass_hash: string; _user: string }
        Returns: Json
      }
      register_product: {
        Args: {
          _brand?: string
          _category?: string
          _code: string
          _name: string
          _photo_path: string
          _price: number
          _qty: number
          _shop: string
          _size?: string
          _type?: Database["public"]["Enums"]["product_type"]
        }
        Returns: {
          archived: boolean
          average_cost: number
          barcode: string | null
          body_color: string | null
          brand: string | null
          catalog_item_id: string | null
          category: string | null
          code: string
          created_at: string
          id: string
          label_color: string | null
          label_text_color: string | null
          name: string
          photo_path: string | null
          photo_url: string | null
          price: number
          product_type: Database["public"]["Enums"]["product_type"]
          shop_id: string
          size: string | null
          stock: number
          updated_at: string
        }
        SetofOptions: {
          from: "*"
          to: "products"
          isOneToOne: true
          isSetofReturn: false
        }
      }
      register_product_with_cost: {
        Args: {
          _brand?: string
          _category?: string
          _code: string
          _name: string
          _photo_path: string
          _price: number
          _qty: number
          _shop: string
          _size?: string
          _type?: Database["public"]["Enums"]["product_type"]
          _unit_cost?: number
        }
        Returns: {
          archived: boolean
          average_cost: number
          barcode: string | null
          body_color: string | null
          brand: string | null
          catalog_item_id: string | null
          category: string | null
          code: string
          created_at: string
          id: string
          label_color: string | null
          label_text_color: string | null
          name: string
          photo_path: string | null
          photo_url: string | null
          price: number
          product_type: Database["public"]["Enums"]["product_type"]
          shop_id: string
          size: string | null
          stock: number
          updated_at: string
        }
        SetofOptions: {
          from: "*"
          to: "products"
          isOneToOne: true
          isSetofReturn: false
        }
      }
      remove_employee_access: {
        Args: { _reason?: string; _shop: string; _user: string }
        Returns: undefined
      }
      set_employee_role: {
        Args: {
          _role: Database["public"]["Enums"]["shop_role"]
          _shop: string
          _user: string
        }
        Returns: undefined
      }
      set_employee_status: {
        Args: {
          _reason?: string
          _shop: string
          _status: string
          _user: string
        }
        Returns: undefined
      }
      set_employee_working_hours: {
        Args: {
          _enabled?: boolean
          _end: string
          _shop: string
          _start: string
          _user: string
          _weekday: number
        }
        Returns: undefined
      }
      undo_sale: {
        Args: { _sale?: string; _shop: string }
        Returns: {
          created_at: string
          id: string
          product_id: string
          product_name: string
          profit_total: number
          qty: number
          shop_id: string
          sold_by: string
          stock_qty: number
          total: number
          undone_at: string | null
          undone_by: string | null
          unit_cost_total: number
          unit_name: string
          unit_price: number
        }
        SetofOptions: {
          from: "*"
          to: "sales"
          isOneToOne: true
          isSetofReturn: false
        }
      }
      update_shop_name: {
        Args: { _name: string; _shop: string }
        Returns: undefined
      }
      write_audit_event: {
        Args: {
          _action: string
          _entity_id: string
          _entity_type: string
          _metadata?: Json
          _shop: string
        }
        Returns: undefined
      }
    }
    Enums: {
      product_type: "beer" | "spirit"
      shop_role: "owner" | "cashier" | "manager" | "inventory_clerk"
    }
    CompositeTypes: {
      [_ in never]: never
    }
  }
}

type DatabaseWithoutInternals = Omit<Database, "__InternalSupabase">

type DefaultSchema = DatabaseWithoutInternals[Extract<keyof Database, "public">]

export type Tables<
  DefaultSchemaTableNameOrOptions extends
    | keyof (DefaultSchema["Tables"] & DefaultSchema["Views"])
    | { schema: keyof DatabaseWithoutInternals },
  TableName extends (DefaultSchemaTableNameOrOptions extends {
    schema: keyof DatabaseWithoutInternals
  }
    ? keyof (DatabaseWithoutInternals[DefaultSchemaTableNameOrOptions["schema"]]["Tables"] &
        DatabaseWithoutInternals[DefaultSchemaTableNameOrOptions["schema"]]["Views"])
    : never) = never,
> = DefaultSchemaTableNameOrOptions extends {
  schema: keyof DatabaseWithoutInternals
}
  ? (DatabaseWithoutInternals[DefaultSchemaTableNameOrOptions["schema"]]["Tables"] &
      DatabaseWithoutInternals[DefaultSchemaTableNameOrOptions["schema"]]["Views"])[TableName] extends {
      Row: infer R
    }
    ? R
    : never
  : DefaultSchemaTableNameOrOptions extends keyof (DefaultSchema["Tables"] &
        DefaultSchema["Views"])
    ? (DefaultSchema["Tables"] &
        DefaultSchema["Views"])[DefaultSchemaTableNameOrOptions] extends {
        Row: infer R
      }
      ? R
      : never
    : never

export type TablesInsert<
  DefaultSchemaTableNameOrOptions extends
    | keyof DefaultSchema["Tables"]
    | { schema: keyof DatabaseWithoutInternals },
  TableName extends (DefaultSchemaTableNameOrOptions extends {
    schema: keyof DatabaseWithoutInternals
  }
    ? keyof DatabaseWithoutInternals[DefaultSchemaTableNameOrOptions["schema"]]["Tables"]
    : never) = never,
> = DefaultSchemaTableNameOrOptions extends {
  schema: keyof DatabaseWithoutInternals
}
  ? DatabaseWithoutInternals[DefaultSchemaTableNameOrOptions["schema"]]["Tables"][TableName] extends {
      Insert: infer I
    }
    ? I
    : never
  : DefaultSchemaTableNameOrOptions extends keyof DefaultSchema["Tables"]
    ? DefaultSchema["Tables"][DefaultSchemaTableNameOrOptions] extends {
        Insert: infer I
      }
      ? I
      : never
    : never

export type TablesUpdate<
  DefaultSchemaTableNameOrOptions extends
    | keyof DefaultSchema["Tables"]
    | { schema: keyof DatabaseWithoutInternals },
  TableName extends (DefaultSchemaTableNameOrOptions extends {
    schema: keyof DatabaseWithoutInternals
  }
    ? keyof DatabaseWithoutInternals[DefaultSchemaTableNameOrOptions["schema"]]["Tables"]
    : never) = never,
> = DefaultSchemaTableNameOrOptions extends {
  schema: keyof DatabaseWithoutInternals
}
  ? DatabaseWithoutInternals[DefaultSchemaTableNameOrOptions["schema"]]["Tables"][TableName] extends {
      Update: infer U
    }
    ? U
    : never
  : DefaultSchemaTableNameOrOptions extends keyof DefaultSchema["Tables"]
    ? DefaultSchema["Tables"][DefaultSchemaTableNameOrOptions] extends {
        Update: infer U
      }
      ? U
      : never
    : never

export type Enums<
  DefaultSchemaEnumNameOrOptions extends
    | keyof DefaultSchema["Enums"]
    | { schema: keyof DatabaseWithoutInternals },
  EnumName extends (DefaultSchemaEnumNameOrOptions extends {
    schema: keyof DatabaseWithoutInternals
  }
    ? keyof DatabaseWithoutInternals[DefaultSchemaEnumNameOrOptions["schema"]]["Enums"]
    : never) = never,
> = DefaultSchemaEnumNameOrOptions extends {
  schema: keyof DatabaseWithoutInternals
}
  ? DatabaseWithoutInternals[DefaultSchemaEnumNameOrOptions["schema"]]["Enums"][EnumName]
  : DefaultSchemaEnumNameOrOptions extends keyof DefaultSchema["Enums"]
    ? DefaultSchema["Enums"][DefaultSchemaEnumNameOrOptions]
    : never

export type CompositeTypes<
  PublicCompositeTypeNameOrOptions extends
    | keyof DefaultSchema["CompositeTypes"]
    | { schema: keyof DatabaseWithoutInternals },
  CompositeTypeName extends (PublicCompositeTypeNameOrOptions extends {
    schema: keyof DatabaseWithoutInternals
  }
    ? keyof DatabaseWithoutInternals[PublicCompositeTypeNameOrOptions["schema"]]["CompositeTypes"]
    : never) = never,
> = PublicCompositeTypeNameOrOptions extends {
  schema: keyof DatabaseWithoutInternals
}
  ? DatabaseWithoutInternals[PublicCompositeTypeNameOrOptions["schema"]]["CompositeTypes"][CompositeTypeName]
  : PublicCompositeTypeNameOrOptions extends keyof DefaultSchema["CompositeTypes"]
    ? DefaultSchema["CompositeTypes"][PublicCompositeTypeNameOrOptions]
    : never

export const Constants = {
  public: {
    Enums: {
      product_type: ["beer", "spirit"],
      shop_role: ["owner", "cashier", "manager", "inventory_clerk"],
    },
  },
} as const
