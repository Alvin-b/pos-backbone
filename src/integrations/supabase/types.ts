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
      products: {
        Row: {
          archived: boolean
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
      sales: {
        Row: {
          created_at: string
          id: string
          product_id: string
          product_name: string
          qty: number
          shop_id: string
          sold_by: string
          total: number
          undone_at: string | null
          undone_by: string | null
          unit_price: number
        }
        Insert: {
          created_at?: string
          id?: string
          product_id: string
          product_name: string
          qty: number
          shop_id: string
          sold_by: string
          total: number
          undone_at?: string | null
          undone_by?: string | null
          unit_price: number
        }
        Update: {
          created_at?: string
          id?: string
          product_id?: string
          product_name?: string
          qty?: number
          shop_id?: string
          sold_by?: string
          total?: number
          undone_at?: string | null
          undone_by?: string | null
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
      shop_members: {
        Row: {
          created_at: string
          role: Database["public"]["Enums"]["shop_role"]
          shop_id: string
          user_id: string
        }
        Insert: {
          created_at?: string
          role?: Database["public"]["Enums"]["shop_role"]
          shop_id: string
          user_id: string
        }
        Update: {
          created_at?: string
          role?: Database["public"]["Enums"]["shop_role"]
          shop_id?: string
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
          created_at: string
          created_by: string
          currency: string
          id: string
          low_stock_threshold: number
          name: string
        }
        Insert: {
          created_at?: string
          created_by: string
          currency?: string
          id?: string
          low_stock_threshold?: number
          name: string
        }
        Update: {
          created_at?: string
          created_by?: string
          currency?: string
          id?: string
          low_stock_threshold?: number
          name?: string
        }
        Relationships: []
      }
      stock_receipts: {
        Row: {
          created_at: string
          id: string
          is_new_product: boolean
          product_id: string
          qty: number
          received_by: string
          shop_id: string
        }
        Insert: {
          created_at?: string
          id?: string
          is_new_product?: boolean
          product_id: string
          qty: number
          received_by: string
          shop_id: string
        }
        Update: {
          created_at?: string
          id?: string
          is_new_product?: boolean
          product_id?: string
          qty?: number
          received_by?: string
          shop_id?: string
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
      create_shop: {
        Args: { _name: string }
        Returns: {
          created_at: string
          created_by: string
          currency: string
          id: string
          low_stock_threshold: number
          name: string
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
      is_shop_member: { Args: { _shop: string }; Returns: boolean }
      is_shop_owner: { Args: { _shop: string }; Returns: boolean }
      receive_stock: {
        Args: { _product: string; _qty: number }
        Returns: {
          archived: boolean
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
          qty: number
          shop_id: string
          sold_by: string
          total: number
          undone_at: string | null
          undone_by: string | null
          unit_price: number
        }
        SetofOptions: {
          from: "*"
          to: "sales"
          isOneToOne: true
          isSetofReturn: false
        }
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
      undo_sale: {
        Args: { _sale?: string; _shop: string }
        Returns: {
          created_at: string
          id: string
          product_id: string
          product_name: string
          qty: number
          shop_id: string
          sold_by: string
          total: number
          undone_at: string | null
          undone_by: string | null
          unit_price: number
        }
        SetofOptions: {
          from: "*"
          to: "sales"
          isOneToOne: true
          isSetofReturn: false
        }
      }
    }
    Enums: {
      product_type: "beer" | "spirit"
      shop_role: "owner" | "cashier"
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
      shop_role: ["owner", "cashier"],
    },
  },
} as const
